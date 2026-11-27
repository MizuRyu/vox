// フィラー除去。規則は ADR-012 の表が正。
// AppKit にも Speech にも依存しない純粋関数として置く（テストから直接叩けるように）。
//
// 適用位置は「セグメントの final を committed に追記する直前」。tentative には適用しない。
// 履歴（R17）に残す raw_text は除去前なので、呼び出し側が別に保持する。

import Foundation

/// 除去の結果。`removedCount` は消した語数（計測 JSONL の `filler_removed_count`）。
public struct FillerRemoval: Equatable, Sendable {
  public let text: String
  public let removedCount: Int

  public init(text: String, removedCount: Int) {
    self.text = text
    self.removedCount = removedCount
  }
}

public enum FillerPass {
  /// ADR-012 の 3 種別。種別ごとに「除去してよい位置」が違う。
  private enum Category {
    /// 単独フィラー。左が読点・句点・空白・文頭なら除去する。
    /// 「えっと」「うーん」の類は後続の語の一部になりえないので、右側の境界は要求しない。
    /// M2 の実測で Apple の出力が「消したいっす。えっとデータ層。」のように読点を挟まないことが
    /// 分かったため（ADR-012「初版。M2 の実測で調整する」）。
    case solo
    /// 読点がなくても拾う長い言いよどみ。引用の中には適用しない。
    case hesitation
    /// 連体詞・副詞の用法があるフィラー（あの・その・まあ）。
    /// 「あのファイルを開いて」を壊さないため、**両側**が境界のときだけ除去する。
    case soloAmbiguous
    /// 相槌。文頭、または読点に挟まれた場合のみ。
    case aizuchi
    /// 感動詞。文頭で直後に境界がある場合のみ。
    case interjection
  }

  /// ADR-012 の表。**「なんか」「なんだっけ」「じゃなくて」は入れない**（誤除去のコストが高い）。
  private static let vocabulary: [(word: [Character], category: Category)] = {
    let entries: [(String, Category)] = [
      ("えっと", .hesitation), ("えーっと", .hesitation), ("えーと", .hesitation), ("えー", .soloAmbiguous),
      ("えと", .soloAmbiguous), ("エット", .soloAmbiguous),
      ("あのー", .solo), ("うーん", .solo), ("んー", .solo),
      ("あの", .soloAmbiguous), ("その", .soloAmbiguous), ("まあ", .soloAmbiguous),
      ("そうそう", .aizuchi), ("うん", .aizuchi), ("はい", .aizuchi),
      ("あー", .interjection), ("あ", .interjection), ("お", .interjection), ("え", .interjection)
    ]
    // 「えー」より先に「えーと」を試すため、長い順に並べる。
    return entries.map { (Array($0.0), $0.1) }.sorted { $0.0.count > $1.0.count }
  }()

  private static let quotePairs: [Character: Character] = ["「": "」", "『": "』", "`": "`", "\"": "\""]
  private static let commas: Set<Character> = ["、", "，"]
  private static let terminators: Set<Character> = ["。", "！", "？", "．", "!", "?"]
  private static let spaces: Set<Character> = [" ", "\u{3000}", "\t", "\n"]

  /// `enabled` が false（`--no-filler-removal`）なら何もしない。
  /// 判定をここに置くことで、フラグの効きを単体テストで担保できる。
  public static func remove(from text: String, enabled: Bool) -> FillerRemoval {
    guard enabled else { return FillerRemoval(text: text, removedCount: 0) }
    return remove(from: text)
  }

  /// フィラーを除去し、続けて連続する読点・句点・空白を 1 つに畳む。
  public static func remove(from text: String) -> FillerRemoval {
    let source = Array(text)
    var kept: [Character] = []
    var removed = 0
    var hadReply = false
    var quotes: [Character] = []
    var backtickCount = 0
    var index = 0

    while index < source.count {
      if let nextIndex = copyProtectedSpan(in: source, from: index, into: &kept, quotes: &quotes, backtickCount: &backtickCount) {
        index = nextIndex
        continue
      }
      if quotes.isEmpty, backtickCount == 0, let match = match(in: source, at: index, kept: kept) {
        let wasSentenceStart = isSentenceStart(kept)
        removed += 1
        hadReply = hadReply || match.isReply
        index += match.length
        if wasSentenceStart {
          index = skipTrailingTerminators(in: source, from: index)
        }
        continue
      }
      kept.append(source[index])
      index += 1
    }

    let cleaned = collapse(kept)
    // 短い返事は残す。ためらい声だけなら空にし、実際に適用した除去数を返す。
    guard cleaned.contains(where: { !$0.isWhitespace && (removed == 0 || !isBoundary($0)) }) else {
      return hadReply ? FillerRemoval(text: text, removedCount: 0) : FillerRemoval(text: "", removedCount: removed)
    }
    return FillerRemoval(text: cleaned, removedCount: removed)
  }

  /// `index` から始まるフィラーを 1 つ探し、除去してよければその長さを返す。
  /// 左の文脈は「ここまでに残した文字列 `kept`」で見る。先行するフィラーを消した結果として
  /// 文頭・読点隣接になった語も、その場で除去できる（「あ、そうそう、」→ 空）。
  private static func match(in source: [Character], at index: Int, kept: [Character]) -> (length: Int, isReply: Bool)? {
    for entry in vocabulary {
      let word = entry.word
      guard index + word.count <= source.count else { continue }
      guard Array(source[index..<(index + word.count)]) == word else { continue }

      let next = index + word.count
      let allowed: Bool
      switch entry.category {
      case .hesitation:
        allowed = true
      case .solo:
        allowed = isBoundary(kept.last)
      case .soloAmbiguous:
        allowed = isBoundary(kept.last) && isBoundary(character(source, at: next))
      case .aizuchi:
        allowed =
          (isSentenceStart(kept) || kept.last.map(commas.contains) == true)
          && isBoundary(character(source, at: next))
      case .interjection:
        allowed =
          isSentenceStart(kept) && isBoundary(character(source, at: next))
      }
      if allowed { return (word.count, entry.category == .aizuchi) }
    }
    return nil
  }

  private static func character(_ source: [Character], at index: Int) -> Character? {
    index < source.count ? source[index] : nil
  }

  /// 引用・複数バッククォート・URL をそのまま写し、次の走査位置を返す。保護対象外なら nil。
  private static func copyProtectedSpan(
    in source: [Character], from index: Int, into output: inout [Character],
    quotes: inout [Character], backtickCount: inout Int
  ) -> Int? {
    let ch = source[index]
    if backtickCount > 0 {
      let run = countBackticks(in: source, from: index)
      if run == backtickCount { backtickCount = 0 }
      let step = max(run, 1)
      output.append(contentsOf: source[index..<(index + step)])
      return index + step
    }
    if quotes.isEmpty, ch == "`" {
      let run = countBackticks(in: source, from: index)
      backtickCount = run
      output.append(contentsOf: source[index..<(index + run)])
      return index + run
    }
    if quotes.isEmpty, let urlEnd = urlEndIndex(in: source, from: index) {
      output.append(contentsOf: source[index..<urlEnd])
      return urlEnd
    }
    if let closing = quotePairs[ch], quotes.last != ch {
      quotes.append(closing)
      output.append(ch)
      return index + 1
    }
    if quotes.last == ch {
      quotes.removeLast()
      output.append(ch)
      return index + 1
    }
    return nil
  }

  private static func countBackticks(in source: [Character], from start: Int) -> Int {
    var count = 0
    while start + count < source.count, source[start + count] == "`" {
      count += 1
    }
    return count
  }

  private static func urlEndIndex(in source: [Character], from start: Int) -> Int? {
    let prefixes = [Array("https://"), Array("http://")]
    guard prefixes.contains(where: { start + $0.count <= source.count && Array(source[start..<(start + $0.count)]) == $0 })
    else { return nil }
    var end = start
    while end < source.count, !spaces.contains(source[end]) {
      end += 1
    }
    return end
  }

  /// 文頭フィラー直後の空白＋文末記号を読み飛ばす（例: `あー !次に進みます。`）。
  private static func skipTrailingTerminators(in source: [Character], from start: Int) -> Int {
    var cursor = start
    while cursor < source.count, spaces.contains(source[cursor]) {
      cursor += 1
    }
    guard cursor < source.count, isSentenceTerminator(source, at: cursor) else { return start }
    while cursor < source.count, isSentenceTerminator(source, at: cursor) {
      cursor += 1
    }
    return cursor
  }

  /// 文末記号か。半角の `?` / `!` は URL クエリやコード記号と区別するため前後を確認する。
  private static func isSentenceTerminator(_ source: [Character], at index: Int) -> Bool {
    let ch = source[index]
    guard terminators.contains(ch) else { return false }
    guard ch == "?" || ch == "!" else { return true }
    if index > 0, source[index - 1] == "/" { return false }
    if index + 1 < source.count, source[index + 1] == "=" || source[index + 1] == "&" { return false }
    return true
  }

  /// 文頭・文末（nil）・読点・句点・空白のいずれか。
  private static func isBoundary(_ character: Character?) -> Bool {
    guard let character else { return true }
    return commas.contains(character) || terminators.contains(character)
      || spaces.contains(character)
  }

  /// 文頭。文字列の先頭、または句点の直後（あいだの読点・空白は読み飛ばす）。
  private static func isSentenceStart(_ kept: [Character]) -> Bool {
    var index = kept.count - 1
    while index >= 0, commas.contains(kept[index]) || spaces.contains(kept[index]) {
      index -= 1
    }
    guard index >= 0 else { return true }
    return terminators.contains(kept[index])
  }

  /// 連続する読点・句点・空白を 1 つに畳み、文頭に残ったものは落とす。
  /// 畳んだ結果は句点 > 読点 > 空白 の順に強いものを残す（「。、」→「。」）。
  private static func collapse(_ characters: [Character]) -> String {
    var output: [Character] = []
    var quotes: [Character] = []
    var backtickCount = 0
    var index = 0
    while index < characters.count {
      if let nextIndex = copyProtectedSpan(in: characters, from: index, into: &output, quotes: &quotes, backtickCount: &backtickCount) {
        index = nextIndex
        continue
      }
      guard quotes.isEmpty, backtickCount == 0, isCollapsible(characters[index]) else {
        output.append(characters[index])
        index += 1
        continue
      }
      var run: [Character] = []
      while index < characters.count, isCollapsible(characters[index]) {
        run.append(characters[index])
        index += 1
      }
      guard !output.isEmpty else { continue }  // 文頭に残った読点・句点・空白は落とす
      if let period = run.first(where: { terminators.contains($0) }) {
        output.append(period)
      } else if let comma = run.first(where: { commas.contains($0) }) {
        output.append(comma)
      } else if let space = run.first {
        output.append(space)
      }
    }
    return String(output)
  }

  /// 畳みの対象。感嘆符・疑問符は連続に意味があるので畳まない。
  private static func isCollapsible(_ character: Character) -> Bool {
    commas.contains(character) || spaces.contains(character) || character == "。"
  }
}

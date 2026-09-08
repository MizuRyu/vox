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
    /// 連体詞・副詞の用法があるフィラー（あの・その・まあ）。
    /// 「あのファイルを開いて」を壊さないため、**両側**が境界のときだけ除去する。
    case soloAmbiguous
    /// 相槌。文頭、または読点に挟まれた場合のみ。
    case aizuchi
    /// 感動詞。文頭で直後に読点がある場合のみ。
    case interjection
  }

  /// ADR-012 の表。**「なんか」「なんだっけ」「じゃなくて」は入れない**（誤除去のコストが高い）。
  private static let vocabulary: [(word: [Character], category: Category)] = {
    let entries: [(String, Category)] = [
      ("えっと", .solo), ("えーっと", .solo), ("えーと", .solo), ("えー", .solo),
      ("あのー", .solo), ("うーん", .solo), ("んー", .solo),
      ("あの", .soloAmbiguous), ("その", .soloAmbiguous), ("まあ", .soloAmbiguous),
      ("そうそう", .aizuchi), ("うん", .aizuchi), ("はい", .aizuchi),
      ("あー", .interjection), ("あ", .interjection), ("お", .interjection), ("え", .interjection)
    ]
    // 「えー」より先に「えーと」を試すため、長い順に並べる。
    return entries.map { (Array($0.0), $0.1) }.sorted { $0.0.count > $1.0.count }
  }()

  private static let commas: Set<Character> = ["、", "，"]
  private static let terminators: Set<Character> = ["。", "！", "？", "．"]
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
    var index = 0

    while index < source.count {
      if let length = matchLength(in: source, at: index, kept: kept) {
        removed += 1
        index += length
        continue
      }
      kept.append(source[index])
      index += 1
    }

    let cleaned = collapse(kept)
    // 全部がフィラーだった発話（「はい」だけ等）は原文を返す。空にすると挿入するものが無くなる。
    guard cleaned.contains(where: { !$0.isWhitespace }) else {
      return FillerRemoval(text: text, removedCount: removed)
    }
    return FillerRemoval(text: cleaned, removedCount: removed)
  }

  /// `index` から始まるフィラーを 1 つ探し、除去してよければその長さを返す。
  /// 左の文脈は「ここまでに残した文字列 `kept`」で見る。先行するフィラーを消した結果として
  /// 文頭・読点隣接になった語も、その場で除去できる（「あ、そうそう、」→ 空）。
  private static func matchLength(in source: [Character], at index: Int, kept: [Character]) -> Int? {
    for entry in vocabulary {
      let word = entry.word
      guard index + word.count <= source.count else { continue }
      guard Array(source[index..<(index + word.count)]) == word else { continue }

      let next = index + word.count
      let allowed: Bool
      switch entry.category {
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
          isSentenceStart(kept) && character(source, at: next).map(commas.contains) == true
      }
      if allowed { return word.count }
    }
    return nil
  }

  private static func character(_ source: [Character], at index: Int) -> Character? {
    index < source.count ? source[index] : nil
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
    var index = 0
    while index < characters.count {
      guard isCollapsible(characters[index]) else {
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

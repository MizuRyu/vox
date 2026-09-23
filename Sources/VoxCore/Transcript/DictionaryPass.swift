// 辞書による表記の置換。規則は ADR-019 の表が正。
// AppKit にも Speech にも依存しない純粋関数として置く（テストから直接叩けるように）。
//
// 適用位置は「セグメントの final を committed に追記する直前、フィラー除去の前」。
// tentative と手入力には掛けない。履歴（R17）に残す raw_text は置換前なので、呼び出し側が別に保持する。
// ファイルの読み込みは VoxApp（DictionaryStore）。ここは本文の解釈と置換だけ。

import Foundation

/// 辞書の 1 項目。`from` は認識される表記、`to` は入れたい表記（空なら削除）。
public struct DictionaryEntry: Equatable, Sendable {
  public let from: String
  public let to: String

  public init(from: String, to: String) {
    self.from = from
    self.to = to
  }
}

/// 辞書ファイル 1 本の解釈結果。`skippedLines` は落とした行の 1 始まりの行番号で、
/// 設定画面が「どの行を直せばよいか」として利用者に出す。
/// 置換は必ずこの型を通す（`entries` の「長い左辺が先」という並びをここだけで作る）。
public struct DictionaryTable: Sendable {
  public let entries: [DictionaryEntry]
  public let skippedLines: [Int]
  public static let empty = Self(entries: [], skippedLines: [])

  private init(entries: [DictionaryEntry], skippedLines: [Int]) {
    self.entries = entries
    self.skippedLines = skippedLines
  }

  /// `置き換える表記<TAB>入れたい表記` の行を読む。`#` で始まる行と空白だけの行は無視し、
  /// 列数が合わない行・左辺が空の行・左辺が重複する行は落として行番号を残す。
  public init(contents: String) {
    let lines = DictionaryLine.parse(contents)
    // 長い左辺から試すために並べ替える（「松尾さん」を「松尾」より先に当てる）。
    entries = lines.compactMap(\.entry).sorted { $0.from.count > $1.from.count }
    skippedLines = lines.indices.filter { lines[$0].isSkipped }.map { $0 + 1 }
  }
}

/// 辞書ファイルの 1 行の解釈。表（`DictionaryTable`）と編集（`DictionaryDocument`）が
/// 同じ規則で読むように、行の判定はここだけに置く。
enum DictionaryLine: Equatable, Sendable {
  case entry(DictionaryEntry)
  /// `#` で始まる行と空白だけの行。
  case ignored(String)
  /// 列数が合わない行・左辺が空の行・左辺が重複する行。
  case skipped(String)

  var entry: DictionaryEntry? {
    if case .entry(let entry) = self { return entry }
    return nil
  }

  var isSkipped: Bool {
    if case .skipped = self { return true }
    return false
  }

  static func parse(_ contents: String) -> [Self] {
    var seen: Set<String> = []
    // why: 区切りは `\.isNewline` で見る。CRLF は 1 Character なので `separator: "\n"` では切れず、
    // 右辺の末尾に見えない改行が残る。
    let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    return lines.map { line in
      if line.hasPrefix("#") || line.allSatisfy(\.isWhitespace) { return .ignored(String(line)) }
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard columns.count == 2, !columns[0].isEmpty, seen.insert(columns[0]).inserted else {
        return .skipped(String(line))
      }
      return .entry(DictionaryEntry(from: columns[0], to: columns[1]))
    }
  }
}

public enum DictionaryPass {
  /// 左辺の長いものから最長一致で置き換える。置換した結果は再走査しないので、
  /// `A → B` と `B → C` は連鎖せず、`あ → ああ` も止まる。
  public static func apply(to text: String, table: DictionaryTable) -> String {
    guard !table.entries.isEmpty, !text.isEmpty else { return text }
    let candidates = table.entries.map { (from: Array($0.from), to: $0.to) }
    let source = Array(text)
    var output = ""
    var index = 0

    while index < source.count {
      if let match = candidates.first(where: { matches($0.from, in: source, at: index) }) {
        output += match.to
        index += match.from.count
        continue
      }
      output.append(source[index])
      index += 1
    }
    return output
  }

  private static func matches(_ word: [Character], in source: [Character], at index: Int) -> Bool {
    guard index + word.count <= source.count else { return false }
    return Array(source[index..<(index + word.count)]) == word
  }
}

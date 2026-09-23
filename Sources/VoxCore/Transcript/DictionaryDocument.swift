// 設定画面の表で辞書ファイルを編集するための、行の位置を保つモデル（ADR-021）。
// 表に出ない行（コメント・空行・壊れた行）は元の位置と元の文字列のまま書き戻す。
// 行の判定は `DictionaryLine`（DictionaryTable と共有）。ファイルの読み書きは VoxApp（DictionaryStore）。

import Foundation

public struct DictionaryDocument: Equatable, Sendable {
  public enum EditFailure: Error, Equatable {
    case emptySource
    case duplicateSource(String)
    /// タブ・改行を含む、または書くとコメントや空行に読まれる表記。
    case unrepresentable
  }

  private var lines: [DictionaryLine]

  public init(contents: String) {
    var lines = DictionaryLine.parse(contents)
    // why: 末尾の改行が作る最後の空要素は行ではない。残すと書き出すたびに空行が増える。
    if lines.last == .ignored("") { lines.removeLast() }
    self.lines = lines
  }

  /// 表に出す行。順番はファイルの順。
  public var entries: [DictionaryEntry] { lines.compactMap(\.entry) }

  /// `.entry` 以外の行は読んだときの文字列のまま。改行は LF、末尾の改行は 1 つ。
  public var serialized: String {
    lines.map { line in
      switch line {
      case .entry(let entry): "\(entry.from)\t\(entry.to)"
      case .ignored(let text), .skipped(let text): text
      }
    }
    .map { $0 + "\n" }
    .joined()
  }

  public mutating func add(_ entry: DictionaryEntry) throws(EditFailure) {
    try validate(entry, replacing: nil)
    lines.append(.entry(entry))
    reparse()
  }

  public mutating func update(at index: Int, entry: DictionaryEntry) throws(EditFailure) {
    let position = linePosition(ofEntry: index)
    try validate(entry, replacing: position)
    lines[position] = .entry(entry)
    reparse()
  }

  public mutating func remove(at index: Int) {
    lines.remove(at: linePosition(ofEntry: index))
    reparse()
  }

  private func linePosition(ofEntry index: Int) -> Int {
    lines.indices.filter { lines[$0].entry != nil }[index]
  }

  private func validate(_ entry: DictionaryEntry, replacing position: Int?) throws(EditFailure) {
    guard !entry.from.isEmpty else { throw .emptySource }
    // why: 書いた 1 行を同じ規則で読み直して同じ項目になるものだけを通す（規則を 2 か所に持たない）。
    guard DictionaryLine.parse("\(entry.from)\t\(entry.to)") == [.entry(entry)] else {
      throw .unrepresentable
    }
    let others = lines.indices.filter { $0 != position }.compactMap { lines[$0].entry }
    guard !others.contains(where: { $0.from == entry.from }) else {
      throw .duplicateSource(entry.from)
    }
  }

  /// why: 編集のたびにファイルと同じ規則で読み直す。先の行を消すと重複で落ちていた行が表に出るなど、
  /// 表とファイルの解釈を食い違わせないため（ファイルが正）。
  private mutating func reparse() {
    self = Self(contents: serialized)
  }
}

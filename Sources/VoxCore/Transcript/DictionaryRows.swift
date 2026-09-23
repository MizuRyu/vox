// 設定画面の辞書の表の行（ADR-021）。行の ID を保存・削除をまたいで保ち、
// セルの打ち込み途中の文字が別の行へ移らないようにする。ファイルに書く内容は `DictionaryDocument`。

import Foundation

public struct DictionaryRow: Identifiable, Equatable, Sendable {
  public let id: Int
  /// 画面に出す値。保存できなかった打ち込みを含む。
  public var entry: DictionaryEntry
}

/// ファイルの項目の行と、その後ろの打ち込み途中の行（1 行まで）。
/// 編集は書く内容（`Save`）を返すだけで、書けたら `apply(_:)` で揃える。
public struct DictionaryRows: Equatable, Sendable {
  /// 書く内容と、書けたときの各項目の行 ID。
  public struct Save: Equatable, Sendable {
    public let document: DictionaryDocument
    fileprivate let ids: [Int]
  }

  public private(set) var document = DictionaryDocument(contents: "")
  public private(set) var rows: [DictionaryRow] = []
  private var nextID = 0

  public init(document: DictionaryDocument) {
    show(document, ids: [])
  }

  /// 末尾に打ち込み途中の行を足す。既にあればその行の ID を返す。
  public mutating func addDraft() -> Int {
    if let draft { return draft.id }
    let row = DictionaryRow(id: newIDs(1)[0], entry: DictionaryEntry(from: "", to: ""))
    rows.append(row)
    return row.id
  }

  /// セルの確定。画面の値は保存できなくても打ち込んだ値にする。表にない ID なら nil。
  public mutating func edit(
    _ id: Int, to entry: DictionaryEntry
  ) throws(DictionaryDocument.EditFailure) -> Save? {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
    rows[index].entry = entry
    var edited = document
    guard index < savedIDs.count else {
      try edited.add(entry)
      return Save(document: edited, ids: savedIDs + [id])
    }
    try edited.update(at: index, entry: entry)
    return Save(document: edited, ids: savedIDs)
  }

  /// 行を消す。打ち込み途中の行は画面から消すだけで nil を返す。
  public mutating func remove(_ id: Int) -> Save? {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
    guard index < savedIDs.count else {
      rows.remove(at: index)
      return nil
    }
    var edited = document
    edited.remove(at: index)
    var ids = savedIDs
    ids.remove(at: index)
    return Save(document: edited, ids: ids)
  }

  public mutating func apply(_ save: Save) {
    show(save.document, ids: save.ids)
  }

  /// 読み直したファイルに揃える。保存できなかった打ち込みはファイルの値に戻し、打ち込み途中の行は残す。
  public mutating func reload(_ document: DictionaryDocument) {
    show(document, ids: savedIDs)
  }

  private var savedIDs: [Int] { rows.prefix(document.entries.count).map(\.id) }
  private var draft: DictionaryRow? { rows.dropFirst(document.entries.count).first }

  /// why: 項目の数が見込みと違う回（重複で落ちていた行が削除で表に出た、外で書き換えた）は、
  /// どの行がどれか分からないので ID を振り直す。
  private mutating func show(_ document: DictionaryDocument, ids: [Int]) {
    let draft = self.draft.flatMap { ids.contains($0.id) ? nil : $0 }
    let entries = document.entries
    let ids = ids.count == entries.count ? ids : newIDs(entries.count)
    self.document = document
    rows = zip(ids, entries).map { DictionaryRow(id: $0, entry: $1) } + [draft].compactMap(\.self)
  }

  private mutating func newIDs(_ count: Int) -> [Int] {
    defer { nextID += count }
    return Array(nextID..<(nextID + count))
  }
}

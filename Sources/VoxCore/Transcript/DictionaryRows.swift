// 設定画面の辞書の表の行（ADR-021）。行の ID を保存・削除をまたいで保ち、
// セルの打ち込み途中の文字が別の行へ移らないようにする。ファイルに書く内容は `DictionaryDocument`。

import Foundation

public struct DictionaryRow: Identifiable, Equatable, Sendable {
  public let id: Int
  /// 画面に出す値。保存できなかった打ち込みを含む。
  public var entry: DictionaryEntry
  /// ファイルにある値。打ち込み途中の行は nil。
  public let saved: DictionaryEntry?

  /// 画面の値がまだファイルに無い。同じ値のままでも確定し直せるようにする。
  public var isPending: Bool { entry != saved }
}

/// ファイルの項目の行と、その後ろの打ち込み途中の行（1 行まで）。
/// 編集は書く内容（`Save`）を返すだけで、書けたら `apply(_:)` で揃える。
public struct DictionaryRows: Equatable, Sendable {
  /// 書く内容と、書けたときに各項目が引き継ぐ行 ID（左辺ごと。左辺はファイルの中で重複しない）。
  public struct Save: Equatable, Sendable {
    public let document: DictionaryDocument
    fileprivate let ids: [String: Int]
  }

  public private(set) var document = DictionaryDocument(contents: "")
  public private(set) var rows: [DictionaryRow] = []
  private var nextID = 0

  public init(document: DictionaryDocument) {
    show(document, ids: [:], keepingPending: false)
  }

  /// 保存できなかった値がある。左の列が空の追加行は打ち込み途中なので数えない（ADR-021）。
  public var hasUnsavedEdits: Bool {
    rows.contains { $0.isPending && ($0.saved != nil || !$0.entry.from.isEmpty) }
  }

  /// 末尾に打ち込み途中の行を足す。既にあればその行の ID を返す。
  public mutating func addDraft() -> Int {
    if let draft { return draft.id }
    let row = DictionaryRow(id: newID(), entry: DictionaryEntry(from: "", to: ""), saved: nil)
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
    if index < document.entries.count {
      try edited.update(at: index, entry: entry)
    } else {
      try edited.add(entry)
    }
    var ids = savedIDs
    rows[index].saved.map { ids[$0.from] = nil }
    ids[entry.from] = id
    return Save(document: edited, ids: ids)
  }

  /// 行を消す。打ち込み途中の行は画面から消すだけで nil を返す。
  public mutating func remove(_ id: Int) -> Save? {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
    guard let saved = rows[index].saved else {
      rows.remove(at: index)
      return nil
    }
    var edited = document
    edited.remove(at: index)
    var ids = savedIDs
    ids[saved.from] = nil
    return Save(document: edited, ids: ids)
  }

  /// 書けた内容に揃える。ほかの行の保存できなかった値は残す。
  public mutating func apply(_ save: Save) {
    show(save.document, ids: save.ids, keepingPending: true)
  }

  /// 読み直したファイルに揃える。外で変わっていたら、どの行がどれか分からないので
  /// ID を振り直して保存できなかった値を捨てる（古いセルの確定を別の行へ通さない）。打ち込み途中の行は残す。
  public mutating func reload(_ document: DictionaryDocument) {
    guard document != self.document else { return }
    show(document, ids: [:], keepingPending: false)
  }

  private var savedIDs: [String: Int] {
    Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.saved.map { ($0.from, row.id) } })
  }

  private var draft: DictionaryRow? { rows.first { $0.saved == nil } }

  /// why: 引き継ぐ ID が無い項目（重複で落ちていた行が編集で表に出た）には新しい ID を振る。
  /// 消した行の ID をほかの行へ回さない。
  private mutating func show(
    _ document: DictionaryDocument, ids: [String: Int], keepingPending: Bool
  ) {
    let draft = self.draft.flatMap { ids.values.contains($0.id) ? nil : $0 }
    let pending = keepingPending ? rows.filter(\.isPending) : []
    self.document = document
    rows = document.entries.map { saved in
      let id = ids[saved.from] ?? newID()
      let shown = pending.first { $0.id == id }?.entry ?? saved
      return DictionaryRow(id: id, entry: shown, saved: saved)
    } + [draft].compactMap(\.self)
  }

  private mutating func newID() -> Int {
    defer { nextID += 1 }
    return nextID
  }
}

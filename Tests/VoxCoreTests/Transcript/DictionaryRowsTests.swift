// DictionaryRows の検査。設定画面の表の行が保存・削除をまたいで同じ ID を保ち、
// 保存できなかった打ち込みが画面の値として残ることを固定する（ADR-021）。合成テキストだけを使う。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: 辞書の表の行")
struct DictionaryRowsTests {
  private let sample = "# 説明\n松尾\t末尾\n壊れた行\nオルカ\tOrca\n"

  private func rows(_ contents: String) -> DictionaryRows {
    DictionaryRows(document: DictionaryDocument(contents: contents))
  }

  @Test("更新と追加では行の ID が変わらない")
  func idsSurviveUpdatesAndAdds() throws {
    var table = rows(sample)
    let ids = table.rows.map(\.id)

    let updateResult = try table.edit(ids[0], to: DictionaryEntry(from: "まつお", to: "末尾"))
    let update = try #require(updateResult)
    table.apply(update)
    #expect(table.rows.map(\.id) == ids, "更新で ID が変わった")

    let draft = table.addDraft()
    let addResult = try table.edit(draft, to: DictionaryEntry(from: "ばぐ", to: "バグ"))
    let add = try #require(addResult)
    #expect(add.document.serialized == "# 説明\nまつお\t末尾\n壊れた行\nオルカ\tOrca\nばぐ\tバグ\n")
    table.apply(add)
    #expect(table.rows.map(\.id) == ids + [draft], "追加した行の ID が打ち込み途中の行と違う")
    #expect(table.rows.last?.entry == DictionaryEntry(from: "ばぐ", to: "バグ"))
  }

  /// 消した行の ID を後ろの行へ回さない（打ち込み途中のセルの文字が別の行へ移らない）。
  @Test("削除した行の ID はほかの行に回らない")
  func removingDoesNotReuseTheID() throws {
    var table = rows("松尾\tX\nオルカ\tX\n")
    let ids = table.rows.map(\.id)

    let removed = table.remove(ids[0])
    let save = try #require(removed)
    #expect(save.document.serialized == "オルカ\tX\n")
    table.apply(save)
    #expect(table.rows.map(\.id) == [ids[1]])
  }

  /// 画面の値は打ち込んだ値になり、隣のセルの確定も画面の値で判断する（左が空なら書かない）。
  @Test("保存できなかった打ち込みは画面の値として残り、ファイルの内容は変わらない")
  func refusedEditsStayOnScreen() throws {
    var table = rows(sample)
    let id = table.rows[0].id

    #expect(throws: DictionaryDocument.EditFailure.emptySource) {
      try table.edit(id, to: DictionaryEntry(from: "", to: "末尾"))
    }
    #expect(table.rows[0].entry == DictionaryEntry(from: "", to: "末尾"), "打ち込みが消えた")
    #expect(throws: DictionaryDocument.EditFailure.emptySource) {
      try table.edit(id, to: DictionaryEntry(from: table.rows[0].entry.from, to: "別"))
    }
    #expect(throws: DictionaryDocument.EditFailure.duplicateSource("オルカ")) {
      try table.edit(id, to: DictionaryEntry(from: "オルカ", to: "別"))
    }
    #expect(table.document.serialized == sample, "拒否した編集で書く内容が変わった")
  }

  @Test("打ち込み途中の行は 1 行だけで、ファイルを読み直しても残る")
  func theDraftIsSingleAndSurvivesReloads() throws {
    var table = rows(sample)
    let draft = table.addDraft()
    #expect(table.addDraft() == draft, "2 行目の空行を足した")
    #expect(throws: DictionaryDocument.EditFailure.emptySource) {
      try table.edit(draft, to: DictionaryEntry(from: "", to: "バグ"))
    }

    let ids = table.rows.map(\.id)
    table.reload(DictionaryDocument(contents: sample))
    #expect(table.rows.map(\.id) == ids, "同じ件数の読み直しで ID が変わった")
    #expect(table.rows.last?.entry == DictionaryEntry(from: "", to: "バグ"), "打ち込み途中の行が消えた")

    let removed = table.remove(draft)
    #expect(removed == nil, "打ち込み途中の行の削除でファイルに書こうとした")
    #expect(table.rows.count == 2)
  }

  /// 行 A の拒否された打ち込みを、行 B の保存で黙って消さない。
  @Test("別の行を保存しても、保存できなかった値は残る")
  func savingAnotherRowKeepsRefusedValues() throws {
    var table = rows(sample)
    let ids = table.rows.map(\.id)
    #expect(throws: DictionaryDocument.EditFailure.emptySource) {
      try table.edit(ids[0], to: DictionaryEntry(from: "", to: "末尾"))
    }
    #expect(table.rows[0].isPending, "拒否された行が保存済みに見える")

    let result = try table.edit(ids[1], to: DictionaryEntry(from: "おるか", to: "Orca"))
    table.apply(try #require(result))
    table.reload(table.document)
    #expect(table.rows[0].entry == DictionaryEntry(from: "", to: "末尾"), "別の行の保存で打ち込みが消えた")
    #expect(table.rows[0].isPending)
    #expect(!table.rows[1].isPending, "保存した行が未保存に見える")
  }

  /// 外で書き換えた後は、どの行がどれか分からない。古い ID の確定を別の行へ通さない。
  @Test("外で変わったファイルを読み直すと ID を振り直し、古い ID の確定を捨てる")
  func externalChangesRenumberRows() throws {
    var table = rows(sample)
    let old = table.rows[0].id
    table.reload(DictionaryDocument(contents: "# 説明\nまつお\t末尾\n壊れた行\nオルカ\tOrca\n"))
    #expect(!table.rows.map(\.id).contains(old), "外の変更の後も古い ID が残った")

    let edited = try table.edit(old, to: DictionaryEntry(from: "松尾", to: "別"))
    #expect(edited == nil, "古い ID の確定が通った")
  }

  @Test("表にない ID の確定と削除は何もしない")
  func unknownIDsAreIgnored() throws {
    var table = rows(sample)
    let before = table
    let edited = try table.edit(999, to: DictionaryEntry(from: "まつお", to: "末尾"))
    let removed = table.remove(999)
    #expect(edited == nil && removed == nil)
    #expect(table == before)
  }
}

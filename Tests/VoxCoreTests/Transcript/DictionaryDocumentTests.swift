// DictionaryDocument の検査。設定画面の表の編集が、表に出ない行（コメント・空行・壊れた行）を
// 元の位置と元の文字列のまま残すことを固定する（ADR-021）。合成テキストだけを使う。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: 辞書の編集")
struct DictionaryDocumentTests {
  private let sample = "# 説明\n松尾\t末尾\n\n壊れた行\nオルカ\tOrca\n"

  @Test("表に出るのは有効な行だけで、順番はファイルの順")
  func entriesFollowTheFileOrder() {
    let document = DictionaryDocument(contents: sample)
    #expect(document.entries == [
      DictionaryEntry(from: "松尾", to: "末尾"), DictionaryEntry(from: "オルカ", to: "Orca")
    ])
  }

  @Test("編集しなければ、書き出しは元の内容と一致する")
  func serializingWithoutEditsKeepsTheContents() {
    #expect(DictionaryDocument(contents: sample).serialized == sample)
    // 正規化は CRLF → LF と、末尾の改行を 1 つにすることだけ。
    #expect(DictionaryDocument(contents: "# 説明\r\n松尾\t末尾").serialized == "# 説明\n松尾\t末尾\n")
    #expect(DictionaryDocument(contents: "").serialized == "")
  }

  @Test("追加は末尾に足し、コメント・空行・壊れた行は位置ごと残る")
  func addingAppendsAndKeepsTheOtherLines() throws {
    var document = DictionaryDocument(contents: sample)
    try document.add(DictionaryEntry(from: "ばぐ", to: "バグ"))
    #expect(document.serialized == sample + "ばぐ\tバグ\n")
    #expect(document.entries.last == DictionaryEntry(from: "ばぐ", to: "バグ"))
  }

  @Test("更新は元の行の位置で書き換える")
  func updatingRewritesInPlace() throws {
    var document = DictionaryDocument(contents: sample)
    try document.update(at: 0, entry: DictionaryEntry(from: "松尾", to: "末尾2"))
    try document.update(at: 1, entry: DictionaryEntry(from: "おるか", to: "Orca"))
    #expect(document.serialized == "# 説明\n松尾\t末尾2\n\n壊れた行\nおるか\tOrca\n")
  }

  @Test("削除は行ごと消し、ほかの行は残る")
  func removingDropsTheLine() {
    var document = DictionaryDocument(contents: sample)
    document.remove(at: 0)
    #expect(document.serialized == "# 説明\n\n壊れた行\nオルカ\tOrca\n")
    #expect(document.entries == [DictionaryEntry(from: "オルカ", to: "Orca")])
  }

  @Test("左辺が空の行と、既にある左辺は保存しない")
  func emptyAndDuplicateSourcesAreRefused() throws {
    var document = DictionaryDocument(contents: sample)
    #expect(throws: DictionaryDocument.EditFailure.emptySource) {
      try document.add(DictionaryEntry(from: "", to: "末尾"))
    }
    #expect(throws: DictionaryDocument.EditFailure.duplicateSource("松尾")) {
      try document.add(DictionaryEntry(from: "松尾", to: "別"))
    }
    #expect(throws: DictionaryDocument.EditFailure.duplicateSource("松尾")) {
      try document.update(at: 1, entry: DictionaryEntry(from: "松尾", to: "Orca"))
    }
    #expect(throws: DictionaryDocument.EditFailure.emptySource) {
      try document.update(at: 0, entry: DictionaryEntry(from: "", to: "末尾"))
    }
    // 自分自身の左辺のままの更新は重複ではない。
    try document.update(at: 0, entry: DictionaryEntry(from: "松尾", to: "末尾"))
    #expect(document.serialized == sample, "拒否した編集でファイルの内容が変わった")
  }

  /// タブ・改行を含む表記と `#` で始まる左辺は、書くと別の行に読まれるので拒否する。
  @Test("ファイルに書くと同じ行に読めない表記は保存しない",
    arguments: ["a\tb", "a\nb", "#松尾", " \t"])
  func unrepresentableEntriesAreRefused(from: String) {
    var document = DictionaryDocument(contents: sample)
    #expect(throws: DictionaryDocument.EditFailure.unrepresentable) {
      try document.add(DictionaryEntry(from: from, to: ""))
    }
    #expect(throws: DictionaryDocument.EditFailure.unrepresentable) {
      try document.add(DictionaryEntry(from: "左辺", to: "右\t辺"))
    }
    #expect(document.serialized == sample)
  }

  @Test("書き出した内容を録音経路が読むと、表と同じ項目になる")
  func serializedContentsReadAsTheSameTable() throws {
    var document = DictionaryDocument(contents: sample)
    try document.add(DictionaryEntry(from: "ばぐ", to: "バグ"))
    try document.update(at: 0, entry: DictionaryEntry(from: "まつお", to: "末尾"))
    document.remove(at: 1)
    let table = DictionaryTable(contents: document.serialized)
    // 表は長い左辺を先に並べ替えるので、順番は比べない。
    let byFrom: (DictionaryEntry, DictionaryEntry) -> Bool = { $0.from < $1.from }
    #expect(table.entries.sorted(by: byFrom) == document.entries.sorted(by: byFrom))
    #expect(table.skippedLines == [4], "壊れた行が位置ごと残っていない")
  }

  /// 重複で落ちていた行は、先の行を消すとファイルの規則どおり表に出る（ファイルが正）。
  @Test("先の行を消すと、重複で落ちていた行が表に出る")
  func removingTheFirstOfADuplicateRevivesTheSecond() {
    var document = DictionaryDocument(contents: "松尾\t末尾\n松尾\t別\n")
    #expect(document.entries == [DictionaryEntry(from: "松尾", to: "末尾")])
    document.remove(at: 0)
    #expect(document.entries == [DictionaryEntry(from: "松尾", to: "別")])
    #expect(document.serialized == "松尾\t別\n")
  }
}

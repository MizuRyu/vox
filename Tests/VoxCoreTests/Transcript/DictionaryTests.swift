// DictionaryPass の規則テスト。規則は ADR-019 が正。
// 表の各行（最長一致、再走査しない、右辺が空、当たらない）と、
// パース（落とす行と 1 始まりの行番号）を固定する。入力は利用者が書く TSV そのままの形で、
// 合成テキストだけを使う。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: 辞書置換")
struct DictionaryTests {
  // MARK: 置換

  @Test("An entry replaces the recognized spelling")
  func anEntryReplacesTheRecognizedSpelling() throws {
    let table = DictionaryTable(contents: "松尾\t末尾")
    #expect(DictionaryPass.apply(to: "配列の松尾を取る", table: table) == "配列の末尾を取る")
  }

  @Test("Every occurrence is replaced")
  func everyOccurrenceIsReplaced() throws {
    let table = DictionaryTable(contents: "松尾\t末尾")
    #expect(DictionaryPass.apply(to: "松尾と松尾", table: table) == "末尾と末尾")
  }

  @Test("An entry replaces at the start and at the end of the text")
  func anEntryReplacesAtTheStartAndAtTheEndOfTheText() throws {
    let table = DictionaryTable(contents: "オルカ\tOrca")
    #expect(DictionaryPass.apply(to: "オルカを開く", table: table) == "Orcaを開く")
    #expect(DictionaryPass.apply(to: "開くのはオルカ", table: table) == "開くのはOrca")
  }

  // MARK: 最長一致

  /// 書いた順ではなく左辺の長さで決まる（短い行が先に書かれていても長い行が勝つ）。
  @Test("The longest matching entry wins")
  func theLongestMatchingEntryWins() throws {
    let table = DictionaryTable(contents: "松尾\t末尾\n松尾さん\tマツオさん")
    #expect(DictionaryPass.apply(to: "松尾さんと松尾", table: table) == "マツオさんと末尾")
  }

  /// 左辺が重複する行は最初の行だけを採る（後の行はパースで落とす）。
  @Test("The first line wins when the same spelling appears twice")
  func theFirstLineWinsWhenTheSameSpellingAppearsTwice() throws {
    let table = DictionaryTable(contents: "松尾\t末尾\n松尾\t待つ\n")
    #expect(table.entries == [DictionaryEntry(from: "松尾", to: "末尾")])
    #expect(table.skippedLines == [2])
  }

  // MARK: 置換した結果は再走査しない

  @Test("A replacement is not rescanned")
  func aReplacementIsNotRescanned() throws {
    let table = DictionaryTable(contents: "A\tB\nB\tC")
    #expect(DictionaryPass.apply(to: "A", table: table) == "B")
  }

  @Test("An entry that contains its own left side terminates")
  func anEntryThatContainsItsOwnLeftSideTerminates() throws {
    let table = DictionaryTable(contents: "あ\tああ")
    #expect(DictionaryPass.apply(to: "あ", table: table) == "ああ")
  }

  // MARK: 右辺が空（ADR-012 で規則から外した語を利用者が消す）

  @Test("An empty right side deletes the word")
  func anEmptyRightSideDeletesTheWord() throws {
    let table = DictionaryTable(contents: "なんか、\t")
    #expect(DictionaryPass.apply(to: "なんか、それは違う", table: table) == "それは違う")
  }

  /// 畳みはしない。読点まで消したいなら左辺に読点を入れる（ADR-019）。
  @Test("Deleting a word keeps the commas around it")
  func deletingAWordKeepsTheCommasAroundIt() throws {
    let table = DictionaryTable(contents: "なんか\t")
    #expect(DictionaryPass.apply(to: "これは、なんか、違う", table: table) == "これは、、違う")
  }

  // MARK: 当たらない

  @Test("An empty table keeps the text")
  func anEmptyTableKeepsTheText() throws {
    #expect(DictionaryPass.apply(to: "配列の松尾を取る", table: .empty) == "配列の松尾を取る")
  }

  @Test("A partial match keeps the text")
  func aPartialMatchKeepsTheText() throws {
    let table = DictionaryTable(contents: "松尾\t末尾")
    #expect(DictionaryPass.apply(to: "松の木", table: table) == "松の木")
  }

  /// 左辺が残りの本文より長い回。境界の外を読まない。
  @Test("An entry longer than the remaining text keeps the text")
  func anEntryLongerThanTheRemainingTextKeepsTheText() throws {
    let table = DictionaryTable(contents: "松尾さんです\t末尾です")
    #expect(DictionaryPass.apply(to: "松尾", table: table) == "松尾")
  }

  @Test("Empty text stays empty")
  func emptyTextStaysEmpty() throws {
    #expect(DictionaryPass.apply(to: "", table: DictionaryTable(contents: "あ\tい")) == "")
  }

  // MARK: パース

  @Test("Comments and blank lines are ignored")
  func commentsAndBlankLinesAreIgnored() throws {
    let table = DictionaryTable(contents: "# これは説明\n\n松尾\t末尾\n")
    #expect(table.entries == [DictionaryEntry(from: "松尾", to: "末尾")])
    #expect(table.skippedLines.isEmpty)
  }

  @Test("A line of only spaces is ignored")
  func aLineOfOnlySpacesIsIgnored() throws {
    let table = DictionaryTable(contents: "　 \n松尾\t末尾")
    #expect(table.entries.count == 1)
    #expect(table.skippedLines.isEmpty)
  }

  @Test("A line without A tab is skipped with its line number")
  func aLineWithoutATabIsSkippedWithItsLineNumber() throws {
    let table = DictionaryTable(contents: "松尾\t末尾\n末尾\n")
    #expect(table.entries == [DictionaryEntry(from: "松尾", to: "末尾")])
    #expect(table.skippedLines == [2])
  }

  @Test("A line with three columns is skipped")
  func aLineWithThreeColumnsIsSkipped() throws {
    let table = DictionaryTable(contents: "松尾\t末尾\tおまけ\n")
    #expect(table.entries.isEmpty)
    #expect(table.skippedLines == [1])
  }

  @Test("A line with an empty left side is skipped")
  func aLineWithAnEmptyLeftSideIsSkipped() throws {
    let table = DictionaryTable(contents: "\t末尾\n")
    #expect(table.entries.isEmpty)
    #expect(table.skippedLines == [1])
  }

  /// 行番号はコメントと空行も数えた 1 始まり。利用者が編集する行と一致させる。
  @Test("Line numbers count comments and blank lines")
  func lineNumbersCountCommentsAndBlankLines() throws {
    let table = DictionaryTable(contents: "# 説明\n\n壊れた行\n松尾\t末尾\n")
    #expect(table.entries == [DictionaryEntry(from: "松尾", to: "末尾")])
    #expect(table.skippedLines == [3])
  }

  @Test("A last line without A newline is read")
  func aLastLineWithoutANewlineIsRead() throws {
    let table = DictionaryTable(contents: "松尾\t末尾")
    #expect(table.entries == [DictionaryEntry(from: "松尾", to: "末尾")])
    #expect(table.skippedLines.isEmpty)
  }

  @Test("An empty right side is A valid entry")
  func anEmptyRightSideIsAValidEntry() throws {
    let table = DictionaryTable(contents: "なんか、\t\n")
    #expect(table.entries == [DictionaryEntry(from: "なんか、", to: "")])
    #expect(table.skippedLines.isEmpty)
  }

  /// CRLF で保存されたファイルで、右辺の末尾に見えない改行文字を残さない。
  @Test("Carriage returns are dropped")
  func carriageReturnsAreDropped() throws {
    let table = DictionaryTable(contents: "松尾\t末尾\r\n")
    #expect(table.entries == [DictionaryEntry(from: "松尾", to: "末尾")])
    #expect(table.skippedLines.isEmpty)
  }

  @Test("An empty file has no entries")
  func anEmptyFileHasNoEntries() throws {
    #expect(DictionaryTable(contents: "").entries.isEmpty)
    #expect(DictionaryTable.empty.entries.isEmpty)
    #expect(DictionaryTable.empty.skippedLines.isEmpty)
  }
}

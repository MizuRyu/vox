// R14 の caret 追記規則、T11 本文バッファ、T15 IME 変換中の編集許可。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: caret と本文バッファ")
struct CaretTests {
  // MARK: caret の追記規則（R14 の「割り込み」）

  @Test("Append moves caret when it was at the end")
  func appendMovesCaretWhenItWasAtTheEnd() throws {
    let result = TranscriptCaret.append("です", to: "テスト", caret: 3)
    expect(result, text: "テストです", caret: 5)
  }

  @Test("Append leaves caret when it was in the middle")
  func appendLeavesCaretWhenItWasInTheMiddle() throws {
    let result = TranscriptCaret.append("です", to: "テスト", caret: 1)
    expect(result, text: "テストです", caret: 1)
  }

  @Test("Append with empty suffix does nothing")
  func appendWithEmptySuffixDoesNothing() throws {
    let result = TranscriptCaret.append("", to: "テスト", caret: 2)
    expect(result, text: "テスト", caret: 2)
  }

  @Test("Append clamps caret beyond the end")
  func appendClampsCaretBeyondTheEnd() throws {
    let result = TranscriptCaret.append("です", to: "テスト", caret: 99)
    expect(result, text: "テストです", caret: 5)
  }

  @Test("Pending suffix returns the appended part")
  func pendingSuffixReturnsTheAppendedPart() throws {
    let suffix = TranscriptCaret.pendingSuffix(current: "テスト", desired: "テストです")
    #expect(suffix == "です", "追記分が違う: \(suffix ?? "nil")")
  }

  /// ユーザーが途中を編集してモデルと分岐したら、ビューには触らない（打った文字を消さない）。
  @Test("Pending suffix is nil when the view diverged")
  func pendingSuffixIsNilWhenTheViewDiverged() throws {
    let suffix = TranscriptCaret.pendingSuffix(current: "テストX", desired: "テストです")
    #expect(suffix == nil, "分岐時に追記しようとした")
  }

  @Test("Pending suffix is nil when equal")
  func pendingSuffixIsNilWhenEqual() throws {
    let suffix = TranscriptCaret.pendingSuffix(current: "テスト", desired: "テスト")
    #expect(suffix == nil, "同一なのに追記しようとした")
  }

  // MARK: T11 本文バッファ（1 つのテキスト領域の状態遷移）

  /// 淡色が差し替わっても、`head` 内の caret は動かない。
  @Test("Tentative update keeps the caret inside head")
  func tentativeUpdateKeepsTheCaretInsideHead() throws {
    var buffer = TranscriptBuffer(head: "テストです", tentative: "きょう", caret: 2)
    buffer.applyTentative("きょうは")
    expect(buffer, head: "テストです", tentative: "きょうは", caret: 2)
  }

  /// 差し替わるのは淡色域だけで、`headEnd` は動かない。
  @Test("Tentative update replaces only the dim tail")
  func tentativeUpdateReplacesOnlyTheDimTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "あああ", caret: 3)
    buffer.applyTentative("い")
    expect(buffer, head: "テスト", tentative: "い", caret: 3)
    #expect((buffer.headEnd == 3) && (buffer.length == 4), "長さが違う: end=\(buffer.headEnd) length=\(buffer.length)")
  }

  /// T21。淡色の直前（`headEnd`）にいた caret は、確定した音声の後ろ（新しい `headEnd`）に移る。
  @Test("Final moves the caret when it was at the head end")
  func finalMovesTheCaretWhenItWasAtTheHeadEnd() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    buffer.commitFinal("です")
    expect(buffer, head: "テストです", tentative: "", caret: 5)
  }

  @Test("Final leaves the caret when it is in the middle")
  func finalLeavesTheCaretWhenItIsInTheMiddle() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 1)
    buffer.commitFinal("です")
    expect(buffer, head: "テストです", tentative: "", caret: 1)
  }

  /// T21。final は淡色をその場で通常色に置き換える（`head` に入り、淡色は空になる）。
  @Test("Final replaces the tentative tail")
  func finalReplacesTheTentativeTail() throws {
    var buffer = TranscriptBuffer(head: "きょうは", tentative: "いい天気", caret: 4)
    buffer.commitFinal("、")
    #expect((buffer.text == "きょうは、") && (buffer.tentative.isEmpty), "並びが違う: \(buffer.text)")
    #expect(buffer.headEnd == 5, "headEnd が進んでいない: \(buffer.headEnd)")
  }

  @Test("Typed text is rejected inside the dim tail from the head side")
  func typedTextIsRejectedInsideTheDimTailFromTheHeadSide() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(buffer.insertTyped("X", at: 4) == false, "淡色域への挿入を受理した")
    expect(buffer, head: "テスト", tentative: "です", caret: 3)
  }

  /// T21。`headEnd`（= 淡色の直前）への挿入は受理し、`head` に入る（淡色より前に打った分）。
  @Test("Typed text at the head end lands in head")
  func typedTextAtTheHeadEndLandsInHead() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(buffer.insertTyped("X", at: 3) == true, "淡色の直前への挿入を拒否した")
    expect(buffer, head: "テストX", tentative: "です", tail: "", caret: 4)
    #expect(buffer.text == "テストXです", "並びが違う: \(buffer.text)")
  }

  @Test("Typed text in the middle moves the caret after it")
  func typedTextInTheMiddleMovesTheCaretAfterIt() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    buffer.insertTyped("ああ", at: 1)
    expect(buffer, head: "テああスト", tentative: "です", caret: 3)
  }

  /// 選択が淡色域に掛かる置換も拒否する。
  @Test("Edit is rejected when the range crosses into the dim tail")
  func editIsRejectedWhenTheRangeCrossesIntoTheDimTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(!buffer.canEdit(range: NSRange(location: 2, length: 3)), "淡色域に跨る範囲を編集可と判定した")
    #expect(buffer.replace(range: NSRange(location: 2, length: 3), with: "") == false, "淡色域に跨る置換を受理した")
    expect(buffer, head: "テスト", tentative: "です", caret: 3)
  }

  @Test("Deletion inside head is accepted")
  func deletionInsideHeadIsAccepted() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(buffer.replace(range: NSRange(location: 1, length: 2), with: "") == true, "head 内の削除を拒否した")
    expect(buffer, head: "テ", tentative: "です", caret: 1)
  }

  // MARK: T15 IME 変換中の編集許可（marked text は head 末尾に置かれる）

  /// 変換中の 2 文字目以降。marked 範囲の置き換えは `headEnd` を越えても許可する。
  @Test("Marked range edit is accepted beyond the head end")
  func markedRangeEditIsAcceptedBeyondTheHeadEnd() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(buffer.canEdit(range: NSRange(location: 3, length: 2), markedLength: 2), "marked 範囲の置き換えを拒否した")
  }

  /// marked 範囲より 1 文字でも長い範囲は淡色域に掛かるので拒否する。
  @Test("Marked range edit is rejected beyond the marked length")
  func markedRangeEditIsRejectedBeyondTheMarkedLength() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(!buffer.canEdit(range: NSRange(location: 3, length: 3), markedLength: 2), "marked 範囲を越える置き換えを受理した")
  }

  /// 先頭が `head` 側に食い込む範囲は許可しない（marked 範囲に収まっていない）。
  @Test("Marked range edit is rejected before the head end")
  func markedRangeEditIsRejectedBeforeTheHeadEnd() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(!buffer.canEdit(range: NSRange(location: 2, length: 3), markedLength: 2), "head に食い込む範囲を marked として受理した")
  }

  /// 変換中でも `head` の編集（別の場所の削除など）は従来どおり通る。
  @Test("Edit inside head is still accepted while composing")
  func editInsideHeadIsStillAcceptedWhileComposing() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(buffer.canEdit(range: NSRange(location: 0, length: 2), markedLength: 2), "変換中に head 内の編集を拒否した")
  }

  /// marked text が無いとき（既定の 0）は淡色域の拒否が変わらない。
  @Test("Without marked text the dim tail stays rejected")
  func withoutMarkedTextTheDimTailStaysRejected() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(
      !buffer.canEdit(range: NSRange(location: 3, length: 1), markedLength: 0)
        && !buffer.canEdit(range: NSRange(location: 3, length: 1)),
      "marked text が無いのに淡色域を編集可と判定した")
  }

  /// 変換中の末尾への 1 文字追加（範囲は空で location が marked の末尾）。
  @Test("Zero length insertion at the marked tail is accepted")
  func zeroLengthInsertionAtTheMarkedTailIsAccepted() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(buffer.canEdit(range: NSRange(location: 5, length: 0), markedLength: 2), "marked 末尾への挿入を拒否した")
  }

  @Test("Negative range is rejected even with marked text")
  func negativeRangeIsRejectedEvenWithMarkedText() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 3)
    #expect(!buffer.canEdit(range: NSRange(location: -1, length: 2), markedLength: 2), "負の位置を受理した")
  }

  /// T21。編集可能域の位置はそのまま、淡色域の内部は全体の末尾に寄せる。
  @Test("Clamp caret keeps the editable positions")
  func clampCaretKeepsTheEditablePositions() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 0)
    #expect(
      buffer.clampCaret(5) == 5
        && buffer.clampCaret(-2) == 0
        && buffer.clampCaret(2) == 2
        && buffer.clampCaret(4) == 5,
      "clamp が違う: \(buffer.clampCaret(5)) / \(buffer.clampCaret(4))")
  }

  /// 丸め先は全体の末尾（`headEnd` ではない）。
  @Test("Set caret is clamped to the overall tail")
  func setCaretIsClampedToTheOverallTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 0)
    buffer.setCaret(99)
    expect(buffer, head: "テスト", tentative: "です", caret: 5)
  }

  /// T21。パレット挿入の既定は全体の末尾（`tail` の末尾）。caret はパスの直後。
  @Test("Palette insertion lands at the overall tail")
  func paletteInsertionLandsAtTheOverallTail() throws {
    var buffer = TranscriptBuffer(head: "ここに", tentative: "しゃべり中", caret: 3)
    buffer.insertPalette("Sources/Vox/App.swift")
    expect(
      buffer, head: "ここに", tentative: "しゃべり中", tail: " Sources/Vox/App.swift ",
      caret: 31)
    #expect(buffer.text == "ここにしゃべり中 Sources/Vox/App.swift ", "並びが違う: \(buffer.text)")
  }

  /// T17。`@` を `head` の途中で打った場合だけ、その位置に入る。
  @Test("Palette insertion at A head location lands there")
  func paletteInsertionAtAHeadLocationLandsThere() throws {
    var buffer = TranscriptBuffer(head: "ここに", tentative: "しゃべり中", caret: 1)
    buffer.insertPalette("a.swift", at: 1)
    expect(buffer, head: "こ a.swift こに", tentative: "しゃべり中", caret: 10)
  }

  @Test("Buffer text is head then tentative")
  func bufferTextIsHeadThenTentative() throws {
    let buffer = TranscriptBuffer(head: "あ", tentative: "い", caret: 1)
    #expect((buffer.text == "あい") && (buffer.length == 2), "全文が違う: \(buffer.text)")
  }

  @Test("Init clamps A caret beyond the overall tail")
  func initClampsACaretBeyondTheOverallTail() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", caret: 99)
    #expect(buffer.caret == 5, "caret が丸まっていない: \(buffer.caret)")
  }
}

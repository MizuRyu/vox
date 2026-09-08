// A-6。committed の追記判定。書記素で比べると、次の final が結合文字から始まる回に
// 「追記ではない」と誤判定して全文を作り直す（filler 除去数が二重に乗る）。

import Testing
import VoxCore

@Suite("Transcript: 追記の差分")
struct TranscriptDeltaTests {
  @Test("結合文字が次の final の先頭に来ても追記と見なす")
  func combiningMarkAtTheBoundaryIsAnAppend() {
    #expect(
      TranscriptDelta.appended(previous: "か", current: "か\u{3099}き") == "\u{3099}き",
      "濁点が分かれた回を追記と見なせない")
  }

  @Test("絵文字の修飾が後から来ても追記と見なす")
  func emojiModifierIsAnAppend() {
    #expect(
      TranscriptDelta.appended(previous: "👍", current: "👍\u{1F3FB}") == "\u{1F3FB}",
      "肌色の修飾が付いた回を追記と見なせない")
  }

  @Test("追記でなければ nil（全文を作り直す合図）")
  func rewrittenTextIsNotAnAppend() {
    #expect(TranscriptDelta.appended(previous: "こんにちは", current: "こんばんは") == nil)
    #expect(TranscriptDelta.appended(previous: "長い本文", current: "長い") == nil, "短くなった回")
  }

  @Test("変わらなければ空の差分")
  func unchangedTextHasAnEmptyDelta() {
    #expect(TranscriptDelta.appended(previous: "同じ", current: "同じ") == "")
    #expect(TranscriptDelta.appended(previous: "", current: "はじめて") == "はじめて")
  }
}

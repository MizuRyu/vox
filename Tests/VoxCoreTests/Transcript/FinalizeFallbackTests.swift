// 確定の締めに失敗したときの分岐。画面に見えている本文は捨てない。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: 確定失敗時の退避")
struct FinalizeFallbackTests {
  @Test("Visible text is handed to the insertion path when finalize fails")
  func testVisibleTextIsHandedToTheInsertionPathWhenFinalizeFails() {
    #expect(
      FinalizeFallback.decide(head: "きょうは", tentative: "いい天気", tail: "メモ")
        == .insert("きょうはいい天気メモ"),
      "the visible text was not handed to the insertion path")
  }

  @Test("Only the tentative text still counts as visible text")
  func testOnlyTheTentativeTextStillCountsAsVisibleText() {
    #expect(
      FinalizeFallback.decide(head: "", tentative: "しゃべっている途中", tail: "")
        == .insert("しゃべっている途中"),
      "a session that failed while still tentative lost its text")
  }

  @Test("An empty screen gives up instead of inserting")
  func testAnEmptyScreenGivesUpInsteadOfInserting() {
    #expect(
      FinalizeFallback.decide(head: "", tentative: "", tail: "") == .giveUp,
      "an empty screen did not give up")
  }
}

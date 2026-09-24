// ADR-022。外部から始めた録音を、発話の後の無音で確定するかの判定。

import Testing
import VoxCore

@Suite("Transcript: 無音での確定")
struct SilenceFinishPolicyTests {
  private let policy = SilenceFinishPolicy(milliseconds: 1_500)

  private func finishes(
    speech: Double?, now: Double, started: Double = 1_000, text: Bool = true, palette: Bool = false,
    pendingSince: Double? = nil
  ) -> Bool {
    policy.shouldFinish(
      lastSpeechMilliseconds: speech, startedMilliseconds: started, now: now, hasText: text,
      paletteOpen: palette, finalizePendingSince: pendingSince)
  }

  @Test("発話が無ければ確定しない")
  func noSpeechNeverFinishes() {
    #expect(!finishes(speech: nil, now: 60_000), "話していないのに確定した")
  }

  @Test("最後の発話から指定の時間黙ったところで確定する")
  func finishesAfterTheSilence() {
    #expect(!finishes(speech: 2_000, now: 3_499), "1,499 ms で確定した")
    #expect(finishes(speech: 2_000, now: 3_500), "1,500 ms 黙っても確定しない")
  }

  @Test("録音開始より前の発話は数えない")
  func speechBeforeStartDoesNotCount() {
    #expect(!finishes(speech: 900, now: 5_000, started: 1_000), "開始前の音で確定した")
  }

  @Test("本文が空なら確定しない")
  func emptyTextDoesNotFinish() {
    #expect(!finishes(speech: 2_000, now: 5_000, text: false), "空のまま確定した")
  }

  @Test("パレットを開いている間は確定しない")
  func paletteOpenHolds() {
    #expect(!finishes(speech: 2_000, now: 5_000, palette: true), "パレット表示中に確定した")
  }

  @Test("区切りの締めが走っている間は待つが、1,000 ms を過ぎたら確定に進む")
  func holdsForAPendingFinalizeOnlyUpToTheLimit() {
    #expect(!finishes(speech: 2_000, now: 5_000, pendingSince: 4_500), "締めの途中で確定した")
    #expect(!finishes(speech: 2_000, now: 5_499, pendingSince: 4_500), "999 ms で待つのをやめた")
    #expect(finishes(speech: 2_000, now: 5_500, pendingSince: 4_500), "返らない締めを待ち続けた")
  }
}

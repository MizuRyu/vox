// ADR-022 / ADR-023。ほかのアプリから始めた録音を、声だけで確定する・やめるかの判定。

import Testing
import VoxCore

@Suite("Transcript: 声だけで使う録音の確定と中止")
struct HandsFreePolicyTests {
  private let policy = HandsFreePolicy(
    finishAfterSilenceMilliseconds: 1_500, cancelIfNoSpeechMilliseconds: 20_000)

  private func action(
    _ policy: HandsFreePolicy? = nil, speech: Double?, now: Double, started: Double = 1_000,
    text: Bool = true, hadInput: Bool = false, palette: Bool = false, pendingSince: Double? = nil
  ) -> HandsFreePolicy.Action {
    (policy ?? self.policy).action(
      lastSpeechMilliseconds: speech, listeningSince: started, now: now, hasText: text,
      hadInput: hadInput, paletteBusy: palette, finalizePendingSince: pendingSince)
  }

  @Test("話し終えて指定の時間黙ったら確定する")
  func finishesAfterTheSilence() {
    #expect(action(speech: 2_000, now: 3_499) == .keep, "1,499 ms で確定した")
    #expect(action(speech: 2_000, now: 3_500) == .finish, "1,500 ms 黙っても確定しない")
  }

  @Test("録音開始より前の音は発話に数えない")
  func speechBeforeStartDoesNotCount() {
    #expect(action(speech: 900, now: 5_000, started: 1_000) == .keep, "開始前の音で確定した")
  }

  @Test("本文が空なら確定しない")
  func emptyTextDoesNotFinish() {
    #expect(action(speech: 2_000, now: 5_000, text: false) == .keep, "空のまま確定した")
  }

  @Test("パレットを開いている間は確定もやめもしない")
  func paletteOpenHolds() {
    #expect(action(speech: 2_000, now: 5_000, palette: true) == .keep, "パレット表示中に確定した")
    #expect(
      action(speech: nil, now: 60_000, text: false, palette: true) == .keep, "パレット表示中にやめた")
  }

  @Test("区切りの締めが走っている間は待つが、1,000 ms を過ぎたら確定に進む")
  func holdsForAPendingFinalizeOnlyUpToTheLimit() {
    #expect(action(speech: 2_000, now: 5_000, pendingSince: 4_500) == .keep, "締めの途中で確定した")
    #expect(action(speech: 2_000, now: 5_499, pendingSince: 4_500) == .keep, "999 ms で待つのをやめた")
    #expect(action(speech: 2_000, now: 5_500, pendingSince: 4_500) == .finish, "返らない締めを待ち続けた")
  }

  @Test("開始から指定の時間、声も手入力も無ければやめる")
  func cancelsWhenNobodySpeaks() {
    #expect(action(speech: nil, now: 20_999, text: false) == .keep, "19,999 ms でやめた")
    #expect(action(speech: nil, now: 21_000, text: false) == .cancel, "20,000 ms 黙っていてもやめない")
  }

  @Test("一度でも話すか打つかしたら、話さない時間ではやめない")
  func speechOrTypingKeepsTheRecording() {
    #expect(action(speech: 5_000, now: 60_000, text: false) == .keep, "話した後の沈黙でやめた")
    #expect(action(speech: nil, now: 60_000, text: true) == .keep, "打った本文を捨てた")
  }

  @Test("打ってから全部消しても、変換中でも、やめない")
  func inputOnceKeepsTheRecording() {
    #expect(action(speech: nil, now: 60_000, text: false, hadInput: true) == .keep, "消した後にやめた")
  }

  @Test("聞き始めた時刻から数える（準備の時間は数えない）")
  func countsFromWhenListeningStarted() {
    #expect(action(speech: nil, now: 30_000, started: 25_000, text: false) == .keep, "準備の時間を数えた")
    #expect(action(speech: nil, now: 45_000, started: 25_000, text: false) == .cancel, "聞き始めから数えていない")
  }

  @Test("指定の無い側は働かない")
  func eachRuleIsOptional() {
    let finishOnly = HandsFreePolicy(finishAfterSilenceMilliseconds: 1_500, cancelIfNoSpeechMilliseconds: nil)
    #expect(action(finishOnly, speech: nil, now: 600_000, text: false) == .keep, "指定が無いのにやめた")
    let cancelOnly = HandsFreePolicy(finishAfterSilenceMilliseconds: nil, cancelIfNoSpeechMilliseconds: 3_000)
    #expect(action(cancelOnly, speech: 2_000, now: 600_000) == .keep, "指定が無いのに確定した")
    #expect(action(cancelOnly, speech: nil, now: 4_000, text: false) == .cancel, "指定したのにやめない")
  }
}

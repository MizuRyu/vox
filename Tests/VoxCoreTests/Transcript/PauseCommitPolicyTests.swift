// ADR-020。発話の後の無音で本体から区切るかの判定。

import Testing
import VoxCore

@Suite("Transcript: 無音での区切り")
struct PauseCommitPolicyTests {
  /// `#expect` の中では mutating を呼べないので、判定を 1 回ぶん外で済ませる。
  private func fires(
    _ policy: inout PauseCommitPolicy, speech: Double?, now: Double, text: Bool = true
  ) -> Bool {
    policy.shouldCommit(lastSpeechMilliseconds: speech, now: now, hasTentativeText: text)
  }

  @Test("発話が無ければ発火しない")
  func noSpeechNeverFires() {
    var policy = PauseCommitPolicy()
    #expect(!fires(&policy, speech: nil, now: 10_000), "発話が無いのに区切った")
  }

  @Test("発話から 700 ms 黙ったところで初めて発火する")
  func firesAfterSevenHundredMillisecondsOfSilence() {
    var policy = PauseCommitPolicy()
    #expect(!fires(&policy, speech: 1_000, now: 1_699), "699 ms で区切った")
    #expect(fires(&policy, speech: 1_000, now: 1_700), "700 ms 黙っても区切らない")
  }

  @Test("発火してから 1,500 ms は、新しい発話の後でも発火しない")
  func minimumIntervalHoldsEvenWithNewSpeech() {
    var policy = PauseCommitPolicy()
    #expect(fires(&policy, speech: 1_000, now: 1_700), "最初の区切りが起きない")
    #expect(!fires(&policy, speech: 1_800, now: 2_600), "前回から 900 ms で区切り直した")
    #expect(!fires(&policy, speech: 1_800, now: 3_199), "前回から 1,499 ms で区切り直した")
    #expect(
      fires(&policy, speech: 1_800, now: 3_200),
      "前回から 1,500 ms 経って新しい発話の後なのに区切らない")
  }

  @Test("前回の発火より後に発話が無ければ、いくら黙っても発火しない")
  func silenceAloneDoesNotFireAgain() {
    var policy = PauseCommitPolicy()
    #expect(fires(&policy, speech: 1_000, now: 1_700), "最初の区切りが起きない")
    #expect(!fires(&policy, speech: 1_000, now: 20_000), "同じ発話で 2 度区切った")
  }

  @Test("未確定の本文が空なら発火せず、その回を消費しない")
  func emptyTentativeWaitsForText() {
    var policy = PauseCommitPolicy()
    #expect(!fires(&policy, speech: 1_000, now: 1_700, text: false), "未確定が空なのに区切った")
    #expect(fires(&policy, speech: 1_000, now: 1_766), "本文が入った後の判定で区切らない")
  }

  @Test("パレットで締めた後も同じ扱いになる")
  func markCommittedCountsAsACommit() {
    var policy = PauseCommitPolicy()
    policy.markCommitted(at: 1_200)
    #expect(!fires(&policy, speech: 1_000, now: 5_000), "パレットで締めた発話をもう一度区切った")
    #expect(!fires(&policy, speech: 1_300, now: 2_600), "パレットで締めてから 1,400 ms で区切った")
    #expect(fires(&policy, speech: 1_300, now: 2_700), "パレットで締めた後の発話を区切らない")
  }
}

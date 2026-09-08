// 録音中の構成変更通知の門。世代が合う最初の 1 回だけ通す。

import Foundation
import Testing
import VoxCore

@Suite("Audio: 収音の中断通知")
struct CaptureInterruptionTests {
  @Test("同じ録音の通知は 1 回だけ通し、前の録音の通知は捨てる")
  func onlyTheFirstNotificationOfTheCurrentRecordingPasses() {
    var lifecycle = RecognitionLifecycle()
    var interruption = CaptureInterruption()
    let first = lifecycle.begin()

    let firstNotification = interruption.decide(generation: first, current: first)
    #expect(firstNotification, "the first configuration change of a recording was dropped")
    let repeated = interruption.decide(generation: first, current: first)
    #expect(!repeated, "a repeated configuration change ended the same recording twice")

    let second = lifecycle.begin()
    let stale = interruption.decide(generation: first, current: second)
    #expect(!stale, "a notification from the previous recording reached the new one")
    let current = interruption.decide(generation: second, current: second)
    #expect(current, "the new recording could not be interrupted")
  }

  @Test("録音が終わった後に届いた通知は捨てる")
  func notificationsAfterTheRecordingEndedAreDropped() {
    var lifecycle = RecognitionLifecycle()
    var interruption = CaptureInterruption()
    let generation = lifecycle.begin()
    lifecycle.finish(generation)

    let late = interruption.decide(generation: generation, current: nil)
    #expect(!late, "a late notification interrupted a recording that already ended")
  }
}

// ADR-020。無音の判定に使う「最後に発話レベルを超えた時刻」。発話開始の検出は変えない。

import Testing
@testable import VoxApp

@Suite("Audio: 発話レベルの追跡")
struct LevelTrackerTests {
  /// ノイズ床 0.01 を 300 ms で決めたところまで進める。
  private func calibrated() -> AudioLevelTracker {
    let tracker = AudioLevelTracker()
    tracker.accept(rms: 0.01, atMilliseconds: 0)
    tracker.accept(rms: 0.01, atMilliseconds: 150)
    tracker.accept(rms: 0.01, atMilliseconds: 300)
    return tracker
  }

  @Test("発話開始は最初の 1 回、最後の発話は超えるたびに進む")
  func lastSpeechFollowsEveryLoudBuffer() {
    let tracker = calibrated()
    #expect(tracker.lastSpeechMilliseconds == nil, "ノイズ床だけで発話にした")
    tracker.accept(rms: 0.1, atMilliseconds: 400)
    tracker.accept(rms: 0.01, atMilliseconds: 500)
    tracker.accept(rms: 0.1, atMilliseconds: 600)
    tracker.accept(rms: 0.01, atMilliseconds: 700)
    #expect(tracker.onsetMilliseconds == 400, "発話開始が最初の 1 回でない")
    #expect(tracker.lastSpeechMilliseconds == 600, "最後の発話が最後に超えた時刻でない")
  }

  @Test("reset で最後の発話も消える")
  func resetClearsLastSpeech() {
    let tracker = calibrated()
    tracker.accept(rms: 0.1, atMilliseconds: 400)
    tracker.reset()
    #expect(tracker.lastSpeechMilliseconds == nil, "前の録音の発話が残った")
  }
}

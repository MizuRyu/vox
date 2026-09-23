import Foundation

/// 発話開始の検出（`speech_onset_ms`）と HUD の波形用のレベル。
/// tap（オーディオスレッド）から書き、MainActor から読むので排他する。
final class AudioLevelTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var floorStartMilliseconds: Double?
  private var floorSum = 0.0
  private var floorCount = 0
  private var noiseFloor: Double?
  private var _onsetMilliseconds: Double?
  private var _level = 0.0

  static let floorWindowMilliseconds = 300.0
  static let onsetMultiplier = 4.0
  static let minimumFloor = 1e-4

  var onsetMilliseconds: Double? { lock.withLock { _onsetMilliseconds } }
  var level: Double { lock.withLock { _level } }

  func reset() {
    lock.withLock {
      floorStartMilliseconds = nil
      floorSum = 0
      floorCount = 0
      noiseFloor = nil
      _onsetMilliseconds = nil
      _level = 0
    }
  }

  func accept(rms: Double, atMilliseconds now: Double) {
    lock.withLock {
      _level = rms
      let start = floorStartMilliseconds ?? now
      floorStartMilliseconds = start
      if noiseFloor == nil {
        if now - start < Self.floorWindowMilliseconds {
          floorSum += rms
          floorCount += 1
          return
        }
        let mean = floorCount > 0 ? floorSum / Double(floorCount) : 0
        noiseFloor = max(mean, Self.minimumFloor)
      }
      guard let floor = noiseFloor, _onsetMilliseconds == nil else { return }
      if rms > floor * Self.onsetMultiplier {
        _onsetMilliseconds = now
      }
    }
  }
}

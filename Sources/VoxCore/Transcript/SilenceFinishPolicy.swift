// ADR-022。ほかのアプリから `finish_after_silence_ms` 付きで始めた録音を、発話の後の無音で確定するか。
// 無音の判定は ADR-020 と同じ「最後に発話レベルを超えた時刻」を使う。

public struct SilenceFinishPolicy: Equatable, Sendable {
  public let silenceMilliseconds: Double

  public init(milliseconds: Int) {
    silenceMilliseconds = Double(milliseconds)
  }

  public func shouldFinish(
    lastSpeechMilliseconds: Double?, startedMilliseconds: Double, now: Double, hasText: Bool,
    paletteOpen: Bool
  ) -> Bool {
    guard let lastSpeechMilliseconds, lastSpeechMilliseconds >= startedMilliseconds,
      hasText, !paletteOpen
    else { return false }
    return now - lastSpeechMilliseconds >= silenceMilliseconds
  }
}

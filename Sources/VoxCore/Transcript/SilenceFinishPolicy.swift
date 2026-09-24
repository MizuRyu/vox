// ADR-022。ほかのアプリから `finish_after_silence_ms` 付きで始めた録音を、発話の後の無音で確定するか。
// 無音の判定は ADR-020 と同じ「最後に発話レベルを超えた時刻」を使う。

public struct SilenceFinishPolicy: Equatable, Sendable {
  /// 区切りの締め（ADR-020）が走っている間は確定を待つ。返らない締めを待ち続けないための上限。
  /// 上限の後は録音キーで確定した時と同じ経路（締めの待ちと本文の救済）に任せる。
  public static let finalizeHoldMilliseconds = 1_000.0
  public let silenceMilliseconds: Double

  public init(milliseconds: Int) {
    silenceMilliseconds = Double(milliseconds)
  }

  public func shouldFinish(
    lastSpeechMilliseconds: Double?, startedMilliseconds: Double, now: Double, hasText: Bool,
    paletteOpen: Bool, finalizePendingSince: Double? = nil
  ) -> Bool {
    guard let lastSpeechMilliseconds, lastSpeechMilliseconds >= startedMilliseconds,
      hasText, !paletteOpen, now - lastSpeechMilliseconds >= silenceMilliseconds
    else { return false }
    guard let finalizePendingSince else { return true }
    return now - finalizePendingSince >= Self.finalizeHoldMilliseconds
  }
}

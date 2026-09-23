// ADR-020。発話の後の無音で、そこまでを本体から確定するか。
// Apple の自発的な区切り（11〜25 秒）を待たずに淡色を通常色にするため。

/// 録音 1 回分。発火したら（またはパレットで締めたら）その時刻を覚え、次の判定の起点にする。
public struct PauseCommitPolicy: Equatable, Sendable {
  public static let silenceMilliseconds = 700.0
  public static let minimumIntervalMilliseconds = 1_500.0

  private var lastCommitMilliseconds: Double?

  public init() {}

  /// 区切るなら true を返し、`now` を前回の区切りとして覚える。
  /// 未確定が空の回は覚えない（本文が届いた後の判定で区切る）。
  public mutating func shouldCommit(
    lastSpeechMilliseconds: Double?, now: Double, hasTentativeText: Bool
  ) -> Bool {
    guard let lastSpeechMilliseconds,
      now - lastSpeechMilliseconds >= Self.silenceMilliseconds,
      hasTentativeText
    else { return false }
    if let lastCommitMilliseconds {
      guard lastSpeechMilliseconds > lastCommitMilliseconds,
        now - lastCommitMilliseconds >= Self.minimumIntervalMilliseconds
      else { return false }
    }
    lastCommitMilliseconds = now
    return true
  }

  /// パレットを開いて締めた時。無音の区切りを短い間隔で重ねない。
  public mutating func markCommitted(at milliseconds: Double) {
    lastCommitMilliseconds = milliseconds
  }
}

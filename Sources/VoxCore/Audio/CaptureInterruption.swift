// 録音中に入力デバイスが変わって engine が止まったときの通知の門。

/// 構成変更の通知は同じ録音に何度も届き、前の録音の分が遅れて届くこともある。
/// 世代が今の録音と一致する最初の 1 回だけ通す。
public struct CaptureInterruption: Sendable {
  private var delivered: RecognitionGeneration?

  public init() {}

  public mutating func decide(
    generation: RecognitionGeneration, current: RecognitionGeneration?
  ) -> Bool {
    guard generation == current, delivered != generation else { return false }
    delivered = generation
    return true
  }
}

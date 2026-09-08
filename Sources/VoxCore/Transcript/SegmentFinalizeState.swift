// A-1。パレットを開いたときの締め（`finalize(through:)`）が終わったかどうか。
// 締めは上限つきで待つだけで取り消さないので、待つのをやめた回もまだ走っている。
// 同じ analyzer に確定の finalize を重ねないため、確定の前にここを見てもう一度待つ。

/// 走っている締めの数。開き直しで 2 つ重なることがあるので真偽値では足りない。
public struct SegmentFinalizeState: Equatable, Sendable {
  private var pending = 0

  public init() {}

  public var hasPending: Bool { pending > 0 }

  public mutating func begin() { pending += 1 }

  public mutating func complete() { pending = max(0, pending - 1) }
}

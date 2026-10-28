// ADR-031。表示用と本文用、2 つの認識器の結果を HUD の (committed, tentative) にまとめる。
// 表示用は `.fastResults` 付きで発話中に文字を出す。`.fastResults` は確定の精度を落とすので
// （実発話 40 本で CER 1.0% → 2.3%）、本文は設定なしの認識器の final だけで作る。
// 表示用の final は、本文用の final がその区間まで届くまで淡色に残す。

public struct SplitTranscript: Equatable, Sendable {
  /// 2 つの認識器は同じ音声を別々に区切る。表示用の final の終わりがこの幅だけ本文用より後ろでも、
  /// 同じ語を含むとみなして捨てる（残すと淡色に同じ語が二重に出る）。
  public static let overlapToleranceSeconds = 0.5

  /// 本文用の final をつないだもの。追記専用（ADR-002）。
  public private(set) var committed = ""
  private var pending: [Segment] = []
  private var volatile = ""
  private var committedEndSeconds = 0.0
  private var finished = false

  private struct Segment: Equatable, Sendable {
    var text: String
    var endSeconds: Double
  }

  public init() {}

  public var tentative: String { pending.map(\.text).joined() + volatile }

  /// why: `endSeconds` は analyzer の時間軸。2 つの認識器で同じ軸なので、区間の終わりで突き合わせられる。
  public mutating func acceptDisplay(_ text: String, isFinal: Bool, endSeconds: Double) {
    guard !finished else { return }
    guard isFinal else {
      volatile = text
      return
    }
    volatile = ""
    if endSeconds > committedEndSeconds + Self.overlapToleranceSeconds {
      pending.append(Segment(text: text, endSeconds: endSeconds))
    }
  }

  public mutating func acceptCommitted(_ text: String, endSeconds: Double) {
    committed += text
    committedEndSeconds = max(committedEndSeconds, endSeconds)
    pending.removeAll { $0.endSeconds <= committedEndSeconds + Self.overlapToleranceSeconds }
  }

  /// 本文用の結果が入力の終わりまで届いた。残る表示用の文字は本文と重なるので捨てる。
  public mutating func finishCommitted() {
    finished = true
    pending = []
    volatile = ""
  }
}

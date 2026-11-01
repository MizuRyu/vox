import Foundation

/// VAD の発話区間を音声窓のフレームへ戻し、無発話中の再認識を止める。
public struct SpeechGate: Sendable {
  public private(set) var windowStartFrame: Int?
  public private(set) var processedFrames = 0
  private var recognizedRanges: [Range<Int>] = []

  public init() {}

  public mutating func begin(windowStartFrame: Int) {
    self.windowStartFrame = windowStartFrame
    processedFrames = 0
    recognizedRanges = []
  }

  public mutating func advance(to frames: Int) { processedFrames = frames }

  public mutating func recognitionRanges(
    regions: [Range<Int>], speakingFrom: Int?, availableFrames: Int
  ) -> [Range<Int>]? {
    var candidates = regions
    if let speakingFrom, speakingFrom < availableFrames { candidates.append(speakingFrom..<availableFrames) }
    var ranges: [Range<Int>] = []
    for candidate in candidates {
      let lower = max(0, candidate.lowerBound)
      let upper = min(availableFrames, candidate.upperBound)
      guard lower < upper else { continue }
      if let last = ranges.last, lower <= last.upperBound {
        ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
      } else {
        ranges.append(lower..<upper)
      }
    }
    guard !ranges.isEmpty, ranges != recognizedRanges else { return nil }
    recognizedRanges = ranges
    // 文中の間は句読点の手がかりになる。前後の無発話だけを除く。
    return [ranges[0].lowerBound..<ranges[ranges.count - 1].upperBound]
  }
}

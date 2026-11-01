import Foundation

/// Haas の入力は 16kHz / Int16 / mono。切り出したフレーム数を保ち、録音との時刻を共有する。
public struct HaasAudioWindow: Sendable {
  public static let sampleRate = 16000
  public static let maximumFrames = 12 * sampleRate
  public private(set) var pcm = Data()
  public private(set) var startFrame = 0
  public var frameCount: Int { pcm.count / 2 }
  public var endFrame: Int { startFrame + frameCount }

  public init() {}

  public mutating func append(_ data: Data) { pcm.append(data) }

  /// 上限の直前 2 秒のうち、20ms のエネルギーが最小の位置で区切る。
  public func quietCutFrames(minimumFrames: Int = 0) -> Int {
    guard frameCount >= Self.maximumFrames else { return frameCount }
    let step = Self.sampleRate / 50
    let lower = max(Self.maximumFrames - 2 * Self.sampleRate, minimumFrames)
    guard lower <= Self.maximumFrames - step else { return Self.maximumFrames }
    var quietest = lower
    var minimum = Double.infinity
    pcm.withUnsafeBytes { bytes in
      for start in stride(from: lower, through: Self.maximumFrames - step, by: step) {
        var energy = 0.0
        for frame in start..<(start + step) {
          let value = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self)))
          energy += value * value
        }
        if energy < minimum {
          minimum = energy
          quietest = start
        }
      }
    }
    return quietest + step / 2
  }

  public func prefix(frames: Int) -> Data { Data(pcm.prefix(frames * 2)) }

  public mutating func consume(frames: Int) {
    pcm = Data(pcm.dropFirst(frames * 2))
    startFrame += frames
  }
}

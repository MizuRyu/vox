// 保存した録音 1 回分の JSON（ADR-026）。wav の形式と、その回の履歴・計測の行をまとめる。
// 書き込みは VoxApp（RecordingWriter）。ここは直列化だけ。

import Foundation

public struct RecordingSidecar: Encodable, Sendable {
  public static let schemaVersion = 1

  public struct Audio: Encodable, Sendable, Equatable {
    /// JSON と同じフォルダにある wav のファイル名。
    public var file: String
    public var sampleRate: Double
    public var channels: Int
    public var frames: Int64
    /// 上限（30 分）を超えて書くのをやめた。
    public var truncated: Bool

    public init(file: String, sampleRate: Double, channels: Int, frames: Int64, truncated: Bool) {
      self.file = file
      self.sampleRate = sampleRate
      self.channels = channels
      self.frames = frames
      self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
      case file
      case sampleRate = "sample_rate"
      case channels
      case frames
      case truncated
    }
  }

  /// 音声を 1 フレームも受け取らなかった回は nil。
  public var audio: Audio?
  /// 最初の音声バッファを受け取った時刻（計測と同じ単調時計）。
  public var captureStartMilliseconds: Double?
  public var history: HistoryRecord
  public var metrics: MetricsRecord?

  public init(
    audio: Audio?, captureStartMilliseconds: Double?, history: HistoryRecord,
    metrics: MetricsRecord?
  ) {
    self.audio = audio
    self.captureStartMilliseconds = captureStartMilliseconds
    self.history = history
    self.metrics = metrics
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case audio
    case captureStartMilliseconds = "capture_start_ms"
    case history
    case metrics
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encodeAlways(audio, forKey: .audio)
    try container.encodeAlways(captureStartMilliseconds, forKey: .captureStartMilliseconds)
    try container.encode(history, forKey: .history)
    try container.encodeAlways(metrics, forKey: .metrics)
  }
}

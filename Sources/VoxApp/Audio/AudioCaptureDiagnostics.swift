import AVFoundation
import Foundation

/// Opt-in aggregate metadata before mono conversion. Never stores samples or transcription.
enum AudioCaptureDiagnostics {
  static func formatSummary(_ format: AVAudioFormat) -> String {
    let tag = format.channelLayout.map { String($0.layoutTag) } ?? "unknown"
    return "sample_rate=\(format.sampleRate) channels=\(format.channelCount) "
      + "interleaved=\(format.isInterleaved) format=\(format.commonFormat.rawValue) layout_tag=\(tag)"
  }

  static func channelSummary(_ buffer: AVAudioPCMBuffer) -> String {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    let reported = min(channels, 8)
    var fields = ["frames=\(frames)", "reported_channels=\(reported)"]
    guard frames > 0, reported > 0 else { return fields.joined(separator: " ") }
    // At most 512 samples per channel; diagnostics must not compete with recognition.
    let strideLength = max(1, (frames + 511) / 512)
    for channel in 0..<reported {
      var sum = 0.0
      var count = 0
      var peak = 0.0
      var invalid = 0
      for frame in stride(from: 0, to: frames, by: strideLength) {
        let plane = buffer.format.isInterleaved ? 0 : channel
        let offset = buffer.format.isInterleaved ? frame * channels + channel : frame
        let value: Double
        if let data = buffer.floatChannelData {
          value = Double(data[plane][offset])
        } else if let data = buffer.int16ChannelData {
          value = Double(data[plane][offset]) / 32768
        } else {
          return "frames=\(frames) sample_format=unsupported"
        }
        guard value.isFinite else { invalid += 1; continue }
        sum += value * value
        peak = max(peak, abs(value))
        count += 1
      }
      let rms = count > 0 ? (sum / Double(count)).squareRoot() : 0
      fields.append(String(format: "ch%d_rms=%.5f ch%d_peak=%.5f ch%d_invalid=%d",
        channel, rms, channel, peak, channel, invalid))
    }
    return fields.joined(separator: " ")
  }
}

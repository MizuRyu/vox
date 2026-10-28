// 認識に渡す前の音声形式の変換と、tap から給餌 Task への受け渡し。

import AVFoundation
import Foundation

/// `AVAudioPCMBuffer` は Sendable ではない。tap から給餌 Task へ渡すだけで、
/// 受け渡し後に tap 側は触らない（プローブと同じ）。
struct BufferBox: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
}

/// サンプルの BufferConverter（プローブからそのまま）。
private final class ConverterInputState: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  var processed = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}

final class BufferConverter {
  enum Failure: Error {
    case failedToCreateConverter
    case failedToCreateConversionBuffer
    case conversionFailed(NSError?)
  }

  private var converter: AVAudioConverter?

  func convertBuffer(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws
    -> AVAudioPCMBuffer {
    // 多チャンネル入力は先に自前でモノラル化する。AVAudioConverter の既定の
    // チャンネル対応は先頭チャンネルしか使わず、「外部マイク」(48kHz/3ch) で先頭が
    // 無音だと analyzer に完全な無音が渡る (実機で peak=0.0000 を確認。T12)。
    // 波形メーターは全チャンネル平均なので「反応はするのに認識しない」矛盾になっていた。
    let buffer = format.channelCount == 1 && source.format.channelCount > 1
      ? try Self.downmixToMono(source) : source
    let inputFormat = buffer.format
    guard inputFormat != format else { return buffer }

    if converter == nil || converter?.outputFormat != format {
      converter = AVAudioConverter(from: inputFormat, to: format)
      // 先頭サンプルの品質を捨てて、変換によるタイムスタンプのずれを避ける（サンプルと同じ）。
      converter?.primeMethod = .none
    }
    guard let converter else { throw Failure.failedToCreateConverter }

    let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
    let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))
    guard
      let conversionBuffer = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat, frameCapacity: frameCapacity)
    else {
      throw Failure.failedToCreateConversionBuffer
    }

    var nsError: NSError?
    let inputState = ConverterInputState(buffer: buffer)
    let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
      defer { inputState.processed = true }
      inputStatusPointer.pointee = inputState.processed ? .noDataNow : .haveData
      return inputState.processed ? nil : inputState.buffer
    }
    guard status != .error else { throw Failure.conversionFailed(nsError) }
    return conversionBuffer
  }

  /// 全チャンネルの平均で 1ch float32 非インターリーブにする。サンプルレートは変えない。
  static func downmixToMono(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    let channels = Int(source.format.channelCount)
    let frames = Int(source.frameLength)
    guard
      let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: source.format.sampleRate,
        channels: 1, interleaved: false),
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))),
      let out = mono.floatChannelData?[0]
    else { throw Failure.failedToCreateConversionBuffer }
    mono.frameLength = AVAudioFrameCount(frames)
    guard frames > 0, channels > 0 else { return mono }
    let scale = 1 / Float(channels)
    if let data = source.floatChannelData {
      if source.format.isInterleaved {
        let p = data[0]
        for i in 0..<frames {
          var sum: Float = 0
          for c in 0..<channels { sum += p[i * channels + c] }
          out[i] = sum * scale
        }
      } else {
        for i in 0..<frames { out[i] = 0 }
        for c in 0..<channels {
          let p = data[c]
          for i in 0..<frames { out[i] += p[i] * scale }
        }
      }
    } else if let data = source.int16ChannelData {
      let planes = source.format.isInterleaved ? 1 : channels
      for i in 0..<frames {
        var sum: Float = 0
        for c in 0..<channels {
          let sample = source.format.isInterleaved ? data[0][i * channels + c] : data[min(c, planes - 1)][i]
          sum += Float(sample) / 32768
        }
        out[i] = sum * scale
      }
    } else {
      throw Failure.failedToCreateConversionBuffer
    }
    return mono
  }
}

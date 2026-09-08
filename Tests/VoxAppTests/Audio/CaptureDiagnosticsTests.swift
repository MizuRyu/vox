// 収録の診断表示。合成バッファだけを見て、入力デバイスは開かない。

import AVFoundation
import Foundation
import Testing
@testable import VoxApp

@Suite("Audio: 収録の診断表示")
struct CaptureDiagnosticsTests {
  @Test("チャンネルごとの実効値と形式をそのまま報告する")
  func channelSummaryReportsEachChannel() throws {
    let layout = try #require(
      AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 24_000, interleaved: false,
      channelLayout: layout)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    let channels = try #require(buffer.floatChannelData)
    for index in 0..<4 {
      channels[0][index] = 0
      channels[1][index] = 0.5
      channels[2][index] = -1
    }
    let summary = AudioCaptureDiagnostics.channelSummary(buffer)
    #expect(summary.contains("ch0_rms=0.00000"), "silent first channel stays identifiable")
    #expect(summary.contains("ch1_rms=0.50000"), "second channel is measured separately")
    #expect(summary.contains("ch2_rms=1.00000"), "opposite polarity is not averaged away")
    #expect(channels[1][0] == 0.5, "diagnosis does not mutate audio")
    #expect(
      AudioCaptureDiagnostics.formatSummary(format).contains("channels=3"),
      "diagnosis reports actual channel count")
    buffer.frameLength = 0
    #expect(
      AudioCaptureDiagnostics.channelSummary(buffer).contains("frames=0"),
      "empty buffer is handled")
  }

  @Test("整数のインターリーブと多チャンネルでも読み違えない")
  func channelSummaryHandlesInterleavedAndManyChannels() throws {
    let intFormat = try #require(
      AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2,
        interleaved: true))
    let intBuffer = try #require(AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 2))
    intBuffer.frameLength = 2
    let samples = try #require(intBuffer.int16ChannelData)
    for index in 0..<2 {
      samples[0][index * 2] = 0
      samples[0][index * 2 + 1] = 16384
    }
    let intSummary = AudioCaptureDiagnostics.channelSummary(intBuffer)
    #expect(
      intSummary.contains("ch0_rms=0.00000") && intSummary.contains("ch1_rms=0.50000"),
      "interleaved integer channels stay separate")

    let manyLayout = try #require(
      AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 10))
    let manyFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false,
      channelLayout: manyLayout)
    let many = try #require(AVAudioPCMBuffer(pcmFormat: manyFormat, frameCapacity: 1))
    many.frameLength = 1
    let manyChannels = try #require(many.floatChannelData)
    for channel in 0..<10 { manyChannels[channel][0] = 0 }
    #expect(
      AudioCaptureDiagnostics.channelSummary(many).contains("reported_channels=8"),
      "diagnostic channel work is bounded")
  }
}

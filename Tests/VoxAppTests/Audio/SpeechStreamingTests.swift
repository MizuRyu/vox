import AVFoundation
import Foundation
import Speech
import Testing

@testable import VoxApp

@Suite("Speech streaming", .serialized)
@MainActor
struct SpeechStreamingTests {
  @Test(
    "Results arrive throughout paced audio before finalization",
    .enabled(if: ProcessInfo.processInfo.environment["VOX_SPEECH_REPLAY_AUDIO"] != nil),
    .timeLimit(.minutes(2)))
  func resultsArriveDuringInput() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOX_SPEECH_REPLAY_AUDIO"])
    let locale = try #require(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja_JP")))
    let installed = await SpeechTranscriber.installedLocales
    try #require(installed.contains { $0.identifier == locale.identifier }, "日本語の認識モデルが必要")

    let (transcriber, analyzer) = SpeechLane.makeRecognizer(locale: locale)
    let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
    let audio = try AVAudioFile(
      forReading: URL(fileURLWithPath: path), commonFormat: format.commonFormat,
      interleaved: format.isInterleaved)
    let seconds = Double(audio.length) / audio.processingFormat.sampleRate
    try #require((15...60).contains(seconds), "15〜60秒の、無音の間を置かない合成音声を使う")

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    var arrivals: [Double] = []
    let reader = Task { @MainActor in
      for try await _ in transcriber.results {
        arrivals.append(voxNowMilliseconds())
      }
    }
    defer { reader.cancel() }
    do {
      try await analyzer.start(inputSequence: stream)
      let started = voxNowMilliseconds()
      try await feed(audio, to: continuation, format: format, started: started)
      let inputEnded = voxNowMilliseconds()
      continuation.finish()
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      let finalizeMilliseconds = voxNowMilliseconds() - inputEnded
      try await reader.value

      let duringInput = arrivals.filter { $0 < inputEnded }
      let firstMilliseconds = try #require(duringInput.first) - started
      let boundaries = [started] + duringInput + [inputEnded]
      let maximumGap = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.max() ?? 0
      let valid = duringInput.count >= 3 && firstMilliseconds < 5_000 && maximumGap < 5_000
      print(
        "\(valid ? "OK" : "NG"): speech_replay first_ms=\(Int(firstMilliseconds)) max_gap_ms=\(Int(maximumGap)) "
          + "during_input=\(duringInput.count) finalize_ms=\(Int(finalizeMilliseconds))")
      #expect(duringInput.count >= 3)
      #expect(firstMilliseconds < 5_000)
      #expect(maximumGap < 5_000)
    } catch {
      continuation.finish()
      await analyzer.cancelAndFinishNow()
      throw error
    }
  }

  private func feed(
    _ audio: AVAudioFile, to continuation: AsyncStream<AnalyzerInput>.Continuation,
    format: AVAudioFormat, started: Double
  ) async throws {
    let inputFormat = audio.processingFormat
    let converter = BufferConverter()
    let chunk = AVAudioFrameCount(inputFormat.sampleRate / 10)
    var frames: Int64 = 0
    while audio.framePosition < audio.length {
      let remaining = audio.length - audio.framePosition
      let count = AVAudioFrameCount(min(Int64(chunk), remaining))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: count))
      try audio.read(into: buffer, frameCount: count)
      guard buffer.frameLength > 0 else { break }
      frames += Int64(buffer.frameLength)
      let converted = try converter.convertBuffer(buffer, to: format)
      let deadline = started + Double(frames) / inputFormat.sampleRate * 1_000
      let wait = deadline - voxNowMilliseconds()
      if wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
      continuation.yield(AnalyzerInput(buffer: converted))
    }
  }
}

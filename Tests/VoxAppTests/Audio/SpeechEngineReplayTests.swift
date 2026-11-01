import AVFoundation
import Foundation
import Testing
import VoxCore
@testable import VoxApp

@Suite("Speech engines: 合成音声の実時間再生", .serialized)
@MainActor
struct SpeechEngineReplayTests {
  @Test(
    "本体の認識器・変換・保存を使い、録音中も結果が出る",
    .enabled(if: ProcessInfo.processInfo.environment["VOX_ENGINE_REPLAY_AUDIO"] != nil),
    .timeLimit(.minutes(3)), arguments: SpeechEngine.allCases)
  func pacedAudio(engine: SpeechEngine) async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOX_ENGINE_REPLAY_AUDIO"])
    let recognizer: any SpeechRecognizer = engine == .haas ? HaasSpeechRecognizer() : AppleSpeechRecognizer()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vox-engine-replay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try #require(RecordingStore(root: root).makeWriter())
    var displayed = ""
    var committed = ""
    var arrivals: [Double] = []
    recognizer.onUpdate = { update in
      if update.isFinal { committed += update.text }
      let text = committed + (update.isFinal ? "" : update.text)
      if text != displayed {
        arrivals.append(voxNowMilliseconds())
        displayed = text
      }
    }
    do {
      let format = try await recognizer.start(onAssetInstallStarted: nil)
      let started = voxNowMilliseconds()
      let frames = try await feed(path: path, format: format, started: started, recognizer: recognizer, writer: writer)
      let ended = voxNowMilliseconds()
      try await recognizer.finish()
      let finalMilliseconds = voxNowMilliseconds() - ended
      let during = arrivals.filter { $0 < ended }
      let first = try #require(during.first) - started
      let boundaries = [started] + during + [ended]
      let gap = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.max() ?? 0
      let valid = first < 5000 && gap < 5000 && finalMilliseconds < 5000 && !committed.isEmpty
      print("\(valid ? "OK" : "NG"): engine_replay engine=\(engine.rawValue) first_ms=\(Int(first)) "
        + "max_gap_ms=\(Int(gap)) finalize_ms=\(Int(finalMilliseconds)) updates=\(during.count)")
      #expect(valid)
      let history = HistoryRecord(
        at: "2026-11-01T00:00:00+09:00", rawText: "合成音声の検査", insertedText: nil,
        targetApp: nil, inserted: false, error: nil, edited: false)
      writer.finish {
        RecordingSidecar(audio: $0, captureStartMilliseconds: nil, history: history, metrics: nil,
          speechModel: engine.modelIdentifier)
      }
      await RecordingWriter.drain()
      #expect(try AVAudioFile(forReading: writer.wav).length == frames)
      let sidecar = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: writer.json)) as? [String: Any])
      #expect(sidecar["speech_model"] as? String == engine.modelIdentifier)
      await recognizer.abort()
    } catch {
      await recognizer.abort()
      writer.discard()
      await RecordingWriter.drain()
      throw error
    }
  }

  private func feed(
    path: String, format: AVAudioFormat, started: Double,
    recognizer: any SpeechRecognizer, writer: RecordingWriter
  ) async throws -> Int64 {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path),
      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    let seconds = Double(file.length) / file.processingFormat.sampleRate
    try #require((15...60).contains(seconds), "15〜60秒の合成音声が必要")
    let converter = BufferConverter()
    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    var read: Int64 = 0
    var written: Int64 = 0
    while file.framePosition < file.length {
      let count = AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
      try file.read(into: buffer, frameCount: count)
      guard buffer.frameLength > 0 else { break }
      read += Int64(buffer.frameLength)
      let delay = started + Double(read) / file.processingFormat.sampleRate * 1000 - voxNowMilliseconds()
      if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
      let converted = try converter.convertBuffer(buffer, to: format)
      writer.append(converted)
      try recognizer.append(converted)
      written += Int64(converted.frameLength)
    }
    return written
  }
}

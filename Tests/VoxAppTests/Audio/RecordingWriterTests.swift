// ADR-026。保存した録音は wav と JSON の組で残り、残さない回は両方消える。一時フォルダで確かめる。

import AVFoundation
import Foundation
import Testing
@testable import VoxApp
import VoxCore

@Suite("Audio: 録音の保存")
struct RecordingWriterTests {
  private func withStore(_ body: (RecordingStore) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vox-recordings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(RecordingStore(root: root))
  }

  /// 合成の無音。analyzer の形式が Int16 の回も Float32 の回もあるので両方で確かめる。
  private func silence(_ format: AVAudioCommonFormat, frames: AVAudioFrameCount) throws
    -> AVAudioPCMBuffer {
    let format = try #require(
      AVAudioFormat(commonFormat: format, sampleRate: 16_000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    return buffer
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func sidecar(_ audio: RecordingSidecar.Audio?) -> RecordingSidecar {
    RecordingSidecar(
      audio: audio, captureStartMilliseconds: 12.5,
      history: HistoryRecord(
        at: "2026-10-18T10:00:00+09:00", rawText: "合成の本文", insertedText: "合成の本文",
        targetApp: nil, inserted: true, error: nil, edited: false),
      metrics: nil)
  }

  @Test("A finished recording leaves a readable wav and a JSON that describes it", arguments: [
    AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32
  ])
  func finishedRecordingLeavesPair(format: AVAudioCommonFormat) async throws {
    try await withStore { store in
      let writer = try #require(store.makeWriter())
      writer.append(try silence(format, frames: 1_600))
      writer.append(try silence(format, frames: 1_600))
      writer.finish { sidecar($0) }
      await waitUntil { (try? Data(contentsOf: writer.json))?.isEmpty == false }

      let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: writer.json)) as? [String: Any])
      let audio = try #require(object["audio"] as? [String: Any])
      #expect(audio["frames"] as? Int == 3_200)
      #expect(audio["file"] as? String == writer.wav.lastPathComponent)
      #expect(object["capture_start_ms"] as? Double == 12.5)
      let file = try AVAudioFile(forReading: writer.wav)
      #expect(file.length == 3_200, "wav length \(file.length)")
      for url in [writer.wav, writer.json] {
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600, "\(url.lastPathComponent) mode \(String(describing: mode))")
      }
    }
  }

  @Test("A discarded recording removes both files, and finish after discard writes nothing")
  func discardRemovesPair() async throws {
    try await withStore { store in
      let writer = try #require(store.makeWriter())
      writer.append(try silence(.pcmFormatInt16, frames: 1_600))
      writer.discard()
      writer.finish { sidecar($0) }
      // 終了処理と同じ待ち方。待った後には何も残っていない。
      await RecordingWriter.drain()
      #expect(!FileManager.default.fileExists(atPath: writer.wav.path))
      #expect(!FileManager.default.fileExists(atPath: writer.json.path))
    }
  }

  @Test("A recording with no audio still writes its JSON with a null audio summary")
  func noAudioWritesNullSummary() async throws {
    try await withStore { store in
      let writer = try #require(store.makeWriter())
      writer.finish { sidecar($0) }
      await waitUntil { (try? Data(contentsOf: writer.json))?.isEmpty == false }
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: writer.json)) as? [String: Any])
      #expect(object["audio"] is NSNull)
    }
  }

  @Test("Two writers made in the same second get different names")
  func sameSecondGetsNextSequence() async throws {
    try await withStore { store in
      let date = Date(timeIntervalSince1970: 1_800_000_000)
      let first = try #require(store.makeWriter(at: date))
      let second = try #require(store.makeWriter(at: date))
      #expect(first.wav != second.wav)
      #expect(second.wav.lastPathComponent.hasSuffix("-02.wav"))
    }
  }
}

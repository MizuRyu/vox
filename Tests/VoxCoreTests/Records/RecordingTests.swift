// ADR-026。保存した録音は wav と JSON の組で回収し、JSON は欠損キーを null で出す。

import Foundation
import Testing
import VoxCore

@Suite("Records: 保存した録音")
struct RecordingTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let day = 24.0 * 60 * 60

  private func file(_ name: String, ageSeconds: Double, bytes: Int = 1) -> AttachmentFile {
    AttachmentFile(name: name, createdAt: now.addingTimeInterval(-ageSeconds), byteCount: bytes)
  }

  @Test("An expired pair is removed together, and a recent pair is kept")
  func expiredPairIsRemovedTogether() {
    let files = [
      file("/r/d/100000-01.wav", ageSeconds: 8 * day),
      file("/r/d/100000-01.json", ageSeconds: 8 * day),
      file("/r/d/120000-01.wav", ageSeconds: 1 * day),
      file("/r/d/120000-01.json", ageSeconds: 1 * day)
    ]
    #expect(
      RecordingRetention.purge(files, now: now) == ["/r/d/100000-01.json", "/r/d/100000-01.wav"])
  }

  @Test("The size limit counts a pair as one and removes the oldest pair first")
  func sizeLimitRemovesWholePairs() {
    let files = [
      file("/r/a.wav", ageSeconds: 300, bytes: 60),
      file("/r/a.json", ageSeconds: 300, bytes: 1),
      file("/r/b.wav", ageSeconds: 100, bytes: 60),
      file("/r/b.json", ageSeconds: 100, bytes: 1)
    ]
    let removed = RecordingRetention.purge(files, now: now, maximumTotalBytes: 100)
    #expect(removed == ["/r/a.json", "/r/a.wav"], "removed \(removed)")
  }

  @Test("A pair is dated by its older file, so a lone stale half does not survive")
  func pairUsesOlderFile() {
    let files = [
      file("/r/a.wav", ageSeconds: 8 * day),
      file("/r/a.json", ageSeconds: 1 * day)
    ]
    #expect(RecordingRetention.purge(files, now: now) == ["/r/a.json", "/r/a.wav"])
  }

  @Test("The sidecar writes every key, with null for missing audio and metrics")
  func sidecarWritesNulls() throws {
    let history = HistoryRecord(
      at: "2026-10-18T10:00:00+09:00", rawText: "合成の本文", insertedText: nil, targetApp: nil,
      inserted: false, error: "empty_text", edited: false)
    let sidecar = RecordingSidecar(
      audio: nil, captureStartMilliseconds: nil, history: history, metrics: nil)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(sidecar)) as? [String: Any])
    #expect(
      Set(object.keys) == ["schema_version", "audio", "capture_start_ms", "history", "metrics"])
    #expect(object["audio"] is NSNull)
    #expect(object["metrics"] is NSNull)
    #expect((object["history"] as? [String: Any])?["raw_text"] as? String == "合成の本文")
  }

  @Test("The audio summary uses snake case keys")
  func audioKeys() throws {
    let audio = RecordingSidecar.Audio(
      file: "100000-01.wav", sampleRate: 16_000, channels: 1, frames: 32_000, truncated: false)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(audio)) as? [String: Any])
    #expect(Set(object.keys) == ["file", "sample_rate", "channels", "frames", "truncated"])
  }
}

// ADR-017 の決定 5。回収は期限と合計上限だけで決め、渡したパスを早く消さない。

import Foundation
import Testing
import VoxCore

@Suite("Attachments: 回収")
struct RetentionTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func file(_ name: String, ageSeconds: Double, bytes: Int = 1) -> AttachmentFile {
    AttachmentFile(
      name: name, createdAt: now.addingTimeInterval(-ageSeconds), byteCount: bytes)
  }

  @Test("Files within the age and size limits are kept")
  func filesWithinTheAgeAndSizeLimitsAreKept() throws {
    let files = [file("a.png", ageSeconds: 0), file("b.png", ageSeconds: 60 * 60 * 24 * 6)]
    #expect(AttachmentRetention.purge(files, now: now).isEmpty, "期限内の添付を消した")
    #expect(AttachmentRetention.purge([], now: now).isEmpty, "空の入力で何かを消そうとした")
  }

  @Test("Files older than the age limit are purged")
  func filesOlderThanTheAgeLimitArePurged() throws {
    let limit = AttachmentRetention.maximumAgeSeconds
    let files = [
      file("old.png", ageSeconds: limit + 1), file("edge.png", ageSeconds: limit),
      file("new.png", ageSeconds: 1)
    ]
    #expect(
      AttachmentRetention.purge(files, now: now) == ["old.png"],
      "期限ちょうどを消した、または期限切れを残した")
  }

  @Test("The total size limit purges the oldest first")
  func theTotalSizeLimitPurgesTheOldestFirst() throws {
    let files = [
      file("1.png", ageSeconds: 300, bytes: 400), file("2.png", ageSeconds: 200, bytes: 400),
      file("3.png", ageSeconds: 100, bytes: 400)
    ]
    #expect(
      AttachmentRetention.purge(files, now: now, maximumTotalBytes: 900) == ["1.png"],
      "合計上限を超えた分を古い順に消していない")
    #expect(
      AttachmentRetention.purge(files, now: now, maximumTotalBytes: 400) == ["1.png", "2.png"],
      "上限に収まるまで消していない")
    #expect(
      AttachmentRetention.purge(files, now: now, maximumTotalBytes: 1200).isEmpty,
      "上限ちょうどで消した")
  }

  /// 期限切れを消した結果が上限に収まるなら、期限内のものは残す。
  @Test("Expired files count toward neither the kept size")
  func expiredFilesCountTowardNeitherTheKeptSize() throws {
    let files = [
      file("expired.png", ageSeconds: AttachmentRetention.maximumAgeSeconds + 1, bytes: 900),
      file("kept.png", ageSeconds: 10, bytes: 400)
    ]
    #expect(
      AttachmentRetention.purge(files, now: now, maximumTotalBytes: 500) == ["expired.png"],
      "期限切れの大きさを残りに数えている")
  }

  /// 時計が戻った端末で作成日時が未来になっても、消さずに残す（消し過ぎない側に倒す）。
  @Test("Files created in the future are kept")
  func filesCreatedInTheFutureAreKept() throws {
    let files = [file("future.png", ageSeconds: -60 * 60 * 24 * 30)]
    #expect(AttachmentRetention.purge(files, now: now).isEmpty, "未来の日時を期限切れにした")
  }
}

// ADR-017。添付のファイル名。日時と連番だけで、地域設定に依存しないこと。

import Foundation
import Testing
import VoxCore

@Suite("Attachments: ファイル名")
struct FileNameTests {
  private func zone(_ identifier: String) throws -> TimeZone {
    try #require(TimeZone(identifier: identifier), "時間帯を作れない: \(identifier)")
  }

  private func date(_ components: DateComponents, in zone: TimeZone) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return try #require(calendar.date(from: components), "日時を作れない")
  }

  @Test("The name is built from the date and A sequence number")
  func theNameIsBuiltFromTheDateAndASequenceNumber() throws {
    let tokyo = try zone("Asia/Tokyo")
    let at = try date(
      DateComponents(year: 2026, month: 9, day: 23, hour: 14, minute: 30, second: 1), in: tokyo)
    #expect(
      AttachmentFileName.relativePath(at: at, sequence: 1, kind: .png, timeZone: tokyo)
        == "20260923/143001-01.png", "名前の形が違う")
    #expect(
      AttachmentFileName.relativePath(at: at, sequence: 2, kind: .png, timeZone: tokyo)
        == "20260923/143001-02.png", "同じ秒で連番が進まない")
    #expect(
      AttachmentFileName.relativePath(at: at, sequence: 0, kind: .png, timeZone: tokyo)
        == "20260923/143001-01.png", "連番が 1 未満でも 01 にしていない")
  }

  @Test("The extension follows the format")
  func theExtensionFollowsTheFormat() throws {
    let tokyo = try zone("Asia/Tokyo")
    let at = try date(
      DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5), in: tokyo)
    #expect(
      AttachmentFileName.relativePath(at: at, sequence: 1, kind: .jpeg, timeZone: tokyo)
        == "20260102/030405-01.jpg", "jpeg の拡張子か 0 詰めが違う")
    #expect(
      AttachmentFileName.relativePath(at: at, sequence: 1, kind: .tiff, timeZone: tokyo)
        == "20260102/030405-01.tiff", "tiff の拡張子が違う")
  }

  /// why: 名前は保存先の一部として本文に入る。私的な文字列（本文、アプリ名）を混ぜない。
  @Test("The name carries nothing but digits and the extension")
  func theNameCarriesNothingButDigitsAndTheExtension() throws {
    let tokyo = try zone("Asia/Tokyo")
    let at = try date(
      DateComponents(year: 2026, month: 9, day: 23, hour: 14, minute: 30, second: 1), in: tokyo)
    let name = AttachmentFileName.relativePath(at: at, sequence: 7, kind: .heic, timeZone: tokyo)
    #expect(name == "20260923/143001-07.heic", "名前に想定外の文字が入っている: \(name)")
  }

  @Test("The time zone decides the day")
  func theTimeZoneDecidesTheDay() throws {
    let tokyo = try zone("Asia/Tokyo")
    let utc = try zone("UTC")
    // 東京の 0:30 は UTC ではまだ前日。日付フォルダは渡した時間帯で決まる。
    let at = try date(
      DateComponents(year: 2026, month: 9, day: 23, hour: 0, minute: 30, second: 0), in: tokyo)
    #expect(
      AttachmentFileName.relativePath(at: at, sequence: 1, kind: .png, timeZone: tokyo)
        == "20260923/003000-01.png", "東京の日付になっていない")
    #expect(
      AttachmentFileName.relativePath(at: at, sequence: 1, kind: .png, timeZone: utc)
        == "20260922/153000-01.png", "UTC の日付になっていない")
  }
}

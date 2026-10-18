// 保存した録音の置き場と回収（ADR-026）。回収の判定は VoxCore の RecordingRetention が持ち、
// ここは列挙と削除だけ。画像（AttachmentStore）と同じく起動時に main actor の外から呼ぶ。

import Foundation
import VoxCore

struct RecordingStore: Sendable {
  /// 同じ秒に始めた 2 回目以降で試す連番の上限。
  private static let sequenceLimit = 99

  let root: URL

  static var standard: RecordingStore {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first
      ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
    return RecordingStore(root: base.appendingPathComponent("vox/recordings"))
  }

  /// wav と JSON の名前を 0600 の空ファイルで押さえてから書き手を返す。押さえられなければ nil。
  func makeWriter(at date: Date = Date()) -> RecordingWriter? {
    let day = DateFormatter.voxRecordingDay.string(from: date)
    let time = DateFormatter.voxRecordingTime.string(from: date)
    for sequence in 1...Self.sequenceLimit {
      let stem = root.appendingPathComponent(day)
        .appendingPathComponent(String(format: "%@-%02d", time, sequence))
      let wav = stem.appendingPathExtension("wav")
      let json = stem.appendingPathExtension("json")
      if FileManager.default.fileExists(atPath: wav.path)
        || FileManager.default.fileExists(atPath: json.path) { continue }
      do {
        try PrivateFileIO.write(Data(), creating: wav)
        try PrivateFileIO.write(Data(), creating: json)
        return RecordingWriter(wav: wav, json: json)
      } catch {
        try? FileManager.default.removeItem(at: wav)
        voxLog("recording_reserve_failed \(String(describing: error))")
        return nil
      }
    }
    voxLog("recording_reserve_failed reason=sequence_exhausted")
    return nil
  }

  /// 期限切れと合計上限を超えた組を消す。消したファイルの数を返す。
  @discardableResult
  func purge(now: Date = Date()) -> Int {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
    guard
      let walker = manager.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return 0 }
    var files: [AttachmentFile] = []
    for case let url as URL in walker {
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
        let createdAt = values.creationDate, let byteCount = values.fileSize
      else { continue }
      files.append(AttachmentFile(name: url.path, createdAt: createdAt, byteCount: byteCount))
    }
    let removed = RecordingRetention.purge(files, now: now)
    for path in removed { try? manager.removeItem(atPath: path) }
    let days = (try? manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
    for day in days where (try? day.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
      if (try? manager.contentsOfDirectory(atPath: day.path))?.isEmpty == true {
        try? manager.removeItem(at: day)
      }
    }
    if !removed.isEmpty { voxLog("recording_purged count=\(removed.count)") }
    return removed.count
  }
}

extension DateFormatter {
  fileprivate static let voxRecordingDay: DateFormatter = fixed("yyyyMMdd")
  fileprivate static let voxRecordingTime: DateFormatter = fixed("HHmmss")

  private static func fixed(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = format
    return formatter
  }
}

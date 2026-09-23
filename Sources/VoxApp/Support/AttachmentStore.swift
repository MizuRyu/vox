// 貼った画像の保存と回収（ADR-017）。形式・名前・寿命の判定は VoxCore の Attachments が持ち、
// ここは読む・書く・消すだけ。保存は main actor の外から呼ぶ（書き込みで HUD を止めない）。

import Foundation
import VoxCore

struct AttachmentStore: Sendable {
  enum SaveOutcome: Equatable {
    /// 保存できた絶対パス。**書き込みが終わってから返す**（本文にパスがあるならファイルがある）。
    case saved(String)
    case failed
  }

  /// 同じ秒に貼った 2 枚目以降で試す連番の上限。
  private static let sequenceLimit = 99

  let root: URL

  static var standard: AttachmentStore {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first
      ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
    return AttachmentStore(root: base.appendingPathComponent("vox/attachments"))
  }

  func save(_ data: Data, kind: AttachmentImageKind, at date: Date = Date()) -> SaveOutcome {
    guard AttachmentImageKind.accepts(byteCount: data.count) else {
      voxLog("attachment_rejected kind=\(kind.rawValue) bytes=\(data.count)")
      return .failed
    }
    for sequence in 1...Self.sequenceLimit {
      let file = root.appendingPathComponent(
        AttachmentFileName.relativePath(
          at: date, sequence: sequence, kind: kind, timeZone: .current))
      if FileManager.default.fileExists(atPath: file.path) { continue }
      do {
        try PrivateFileIO.write(data, creating: file)
        voxLog(
          "attachment_saved kind=\(kind.rawValue) bytes=\(data.count) "
            + "path=\(voxLoggable(path: file.path))")
        return .saved(file.path)
      } catch {
        voxLog("attachment_save_failed kind=\(kind.rawValue) bytes=\(data.count)")
        return .failed
      }
    }
    voxLog("attachment_save_failed kind=\(kind.rawValue) bytes=\(data.count)")
    return .failed
  }

  /// 期限切れと合計上限を超えた分を消す。消した数を返す。
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
    let removed = AttachmentRetention.purge(files, now: now)
    for path in removed { try? manager.removeItem(atPath: path) }
    // ファイルを消しただけでは日付のフォルダが残り続けるので、空になったものは畳む。
    let days = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for day in days where (try? manager.contentsOfDirectory(atPath: day.path))?.isEmpty == true {
      try? manager.removeItem(at: day)
    }
    if !removed.isEmpty { voxLog("attachment_purged count=\(removed.count)") }
    return removed.count
  }
}

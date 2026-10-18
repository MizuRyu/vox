// 保存した録音の回収（ADR-026）。wav と JSON を同じ名前の組として扱い、組ごと消す。
// why: ファイル単位で消すと、片方だけ残って音声と本文の対応が切れる。

import Foundation

public enum RecordingRetention {
  public static let maximumAgeSeconds = AttachmentRetention.maximumAgeSeconds
  public static let maximumTotalBytes = AttachmentRetention.maximumTotalBytes

  /// 消すファイル名を返す。組の作成日時は早い方、大きさは合計で判定する。
  public static func purge(
    _ files: [AttachmentFile], now: Date, maximumAgeSeconds: Double = maximumAgeSeconds,
    maximumTotalBytes: Int = maximumTotalBytes
  ) -> [String] {
    let groups = Dictionary(grouping: files) { stem(of: $0.name) }
    let pairs = groups.map { stem, members in
      AttachmentFile(
        name: stem, createdAt: members.map(\.createdAt).min() ?? now,
        byteCount: members.reduce(0) { $0 + $1.byteCount })
    }
    let removed = AttachmentRetention.purge(
      pairs, now: now, maximumAgeSeconds: maximumAgeSeconds, maximumTotalBytes: maximumTotalBytes)
    return removed.flatMap { stem in (groups[stem] ?? []).map(\.name).sorted() }
  }

  static func stem(of name: String) -> String {
    let url = URL(fileURLWithPath: name)
    return url.deletingPathExtension().path
  }
}

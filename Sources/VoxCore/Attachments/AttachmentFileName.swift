// 添付のファイル名（ADR-017 の決定 6）。名前に入るのは日時と連番だけで、
// 発話内容・貼り付け先アプリ名・画像の内容は入れない。
// why: 表記を `DateFormatter` に任せると地域設定で暦や数字が変わる。成分から自分で組む。

import Foundation

public enum AttachmentFileName {
  /// `<yyyyMMdd>/<HHmmss>-<nn>.<拡張子>`。連番は同じ秒に複数枚を貼ったときの衝突を避ける。
  public static func relativePath(
    at date: Date, sequence: Int, kind: AttachmentImageKind, timeZone: TimeZone
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d%02d%02d/%02d%02d%02d-%02d.%@",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
      max(1, sequence), kind.fileExtension)
  }
}

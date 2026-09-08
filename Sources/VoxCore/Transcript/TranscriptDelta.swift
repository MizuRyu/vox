// A-6。速報レーンの committed は追記専用（ADR-002）。その追記分を取り出す。

import Foundation

public enum TranscriptDelta {
  /// why: 比較は Unicode スカラー列で行う。書記素では、次の final が結合文字（濁点・絵文字の
  /// 修飾）から始まる回に前回分が prefix と見なされない。追記でなければ nil。
  public static func appended(previous: String, current: String) -> String? {
    let previousScalars = previous.unicodeScalars
    let currentScalars = current.unicodeScalars
    guard currentScalars.starts(with: previousScalars) else { return nil }
    return String(String.UnicodeScalarView(currentScalars.dropFirst(previousScalars.count)))
  }
}

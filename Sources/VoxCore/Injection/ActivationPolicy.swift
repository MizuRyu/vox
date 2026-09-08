// R16。挿入先を前面に戻す判定。時間の進み方と NSRunningApplication は呼び出し側に置き、
// 「呼ぶかどうか」「タイムアウトをどう記録するか」だけをここで決める（テストのため）。

import Foundation

public enum ActivationPolicy {
  /// activate の完了を待つ上限。
  public static let timeoutMilliseconds = 500.0
  /// 前面アプリを見に行く間隔。
  public static let pollIntervalMilliseconds = 20.0
  public static let timeoutError = "target_activate_timeout"

  /// 前面が既に挿入先なら activate を呼ばない（通常経路。軸 A に上乗せしない）。
  /// 挿入先が分からない場合も呼ばない。
  public static func needsActivation(frontmostProcessID: Int32?, targetProcessID: Int32?) -> Bool {
    guard let targetProcessID else { return false }
    return frontmostProcessID != targetProcessID
  }

  /// 計測 JSONL の `target_activate_ms` と `error`。
  /// activate を呼ばなかったときは両方とも nil（呼んでいないので所要時間もない）。
  public static func outcome(becameFrontmost: Bool, elapsedMilliseconds: Double)
    -> (milliseconds: Double?, error: String?) {
    becameFrontmost ? (elapsedMilliseconds, nil) : (elapsedMilliseconds, timeoutError)
  }
}

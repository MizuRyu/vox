// M3。パレットを開く前に tentative を締めるときの `analyzer.finalize(through:)` の位置。
//
// `through: nil` は「入力の終端まで確定」を意味し、入力が終わるまで返らない
// （M0 E7 で実測。給餌ループ内で nil を呼ぶと結果を出したあと 600s 超ハングした。
// docs/m0-results.md 追記 04:10 の表）。パレット中は給餌を止めていて入力は終わらないので、
// **給餌済みの位置を明示する**。Sources/VoxM0/main.swift の定期 finalize と同じ形。
//
// 「まだ送っていない位置を指定しない」ことがこの計算の目的なので、
// 給餌済みより一定量手前を返し、給餌済み位置を超えないことをテストで縛る。

import Foundation

public enum AnalyzerFinalizePoint {
  /// 給餌済み位置からどれだけ手前を確定させるか（VoxM0 の定期 finalize と同じ 100ms）。
  public static let safetyMarginSeconds = 0.1

  /// `fedFrameCount` は analyzer へ yield 済みのフレーム数、`sampleRate` は analyzer の形式。
  /// 確定させるべき区間が無い（給餌がマージンに届いていない）ときは nil を返し、
  /// 呼び出し側は finalize を呼ばない。
  public static func throughSeconds(
    fedFrameCount: Int64, sampleRate: Double, marginSeconds: Double = safetyMarginSeconds
  ) -> Double? {
    guard sampleRate > 0, fedFrameCount > 0 else { return nil }
    let fedSeconds = Double(fedFrameCount) / sampleRate
    let through = fedSeconds - max(0, marginSeconds)
    guard through > 0 else { return nil }
    // 丸めの都合でも給餌済みを超えさせない。
    return min(through, fedSeconds)
  }
}

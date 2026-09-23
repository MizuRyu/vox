import Foundation

/// 確定差分を「HUD に出して貼り付ける形」に直す。本体（App.swift の clean）と検査が
/// 同じ順序を通るように、順序はここだけに置く。
public enum CommittedText {
  /// why: 辞書 → フィラー除去の順（ADR-019 → ADR-012）。逆順にすると、フィラーと同じ音で
  /// 始まる誤認識（「えーあい」）の頭が先に削られ、利用者が履歴の raw_text で見た左辺が残らない。
  public static func clean(
    _ delta: String, dictionary: DictionaryTable, fillerRemovalEnabled: Bool
  ) -> FillerRemoval {
    FillerPass.remove(
      from: DictionaryPass.apply(to: delta, table: dictionary), enabled: fillerRemovalEnabled)
  }
}

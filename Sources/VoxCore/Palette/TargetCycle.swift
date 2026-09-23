// T38-c。検索対象の候補をキー 1 つで巡回する輪。
// 候補の集め方は VoxApp（PaletteModel）、切り替えは PaletteCoordinator。

import Foundation

public struct TargetCycle: Equatable, Sendable {
  /// 候補の後ろに、写し取った時点の対象が付く並び。
  private let targets: [PaletteTarget]
  private var position: Int

  /// why: 切り替えると今の対象は候補から外れて元の対象が候補に入る。輪を写し取らずに
  /// 毎回候補を数え直すと、2 つのフォルダを往復するだけで 3 つ目に進めない。
  public init(current: PaletteTarget?, candidates: [PaletteTarget]) {
    targets = candidates.isEmpty ? [] : candidates + (current.map { [$0] } ?? [])
    position = max(0, targets.count - 1)
  }

  public var isEmpty: Bool { targets.isEmpty }

  /// 次の対象。末尾まで進んだら先頭に戻る。
  public mutating func next() -> PaletteTarget? {
    guard !targets.isEmpty else { return nil }
    position = (position + 1) % targets.count
    return targets[position]
  }
}

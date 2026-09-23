// T23 選び直した検索対象の寿命。開き直しても同じフォルダで、録音の後片付けで自動解決に戻る。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 選び直した検索対象")
struct CoordinatorTargetTests {
  /// `.targetResolved` に出た `palette_target_source` を順に拾う。
  private func sources(of coordinator: PaletteCoordinator, into log: Box) {
    coordinator.onMetric = { metric in
      if case .targetResolved(let source) = metric { log.values.append(source) }
    }
  }

  @MainActor
  final class Box {
    var values: [String?] = []
  }

  private func waitForSource(_ log: Box, count: Int) async {
    for _ in 0..<500 {
      if log.values.count >= count { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  @Test("選び直したフォルダは開き直しても続き、録音の後片付けで自動解決に戻る")
  func aChosenFolderSurvivesReopeningAndIsClearedByReset() async throws {
    // 自動解決でリポジトリを走査させない（決まらない回を「特定できず」にする）。
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vox-chosen-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = Box()
    let coordinator = PaletteCoordinator(hud: HudPanel())
    sources(of: coordinator, into: log)

    coordinator.open(atMilliseconds: 0, typedAt: nil)
    await waitForSource(log, count: 1)
    #expect(log.values == [nil], "自動解決の回が記録されていない: \(log.values)")

    coordinator.switchTarget(to: PaletteTarget(root: directory.path, source: .manual))
    #expect(log.values.last == "manual", "選び直した回の source が違う: \(log.values)")
    coordinator.close(insert: nil, fileNameOnly: false)

    coordinator.open(atMilliseconds: 1, typedAt: nil)
    await waitForSource(log, count: 3)
    #expect(
      log.values.last == "manual", "開き直したら自動解決に戻った: \(log.values)")
    coordinator.close(insert: nil, fileNameOnly: false)

    // 録音 1 回分の後片付け。次の録音は自動解決から始まる。
    coordinator.reset()
    coordinator.open(atMilliseconds: 2, typedAt: nil)
    await waitForSource(log, count: 4)
    #expect(
      log.values == [nil, "manual", "manual", nil],
      "後片付けの後も選び直した対象が残った: \(log.values)")
    coordinator.close(insert: nil, fileNameOnly: false)
  }

  @Test("esc はフォルダ選択モードを抜けるだけで、ファイル検索では閉じる")
  func escapeLeavesTheFolderPickerBeforeClosingThePalette() {
    let model = PaletteModel()
    #expect(!model.consumeEscape(), "ファイル検索の esc を候補側が食べた")

    model.setPickingFolder(true)
    #expect(model.consumeEscape(), "フォルダ選択モードの esc を食べていない")
    #expect(!model.isPickingFolder, "esc でモードを抜けていない")
    #expect(!model.consumeEscape(), "抜けた後の esc をもう一度食べた")
  }
}

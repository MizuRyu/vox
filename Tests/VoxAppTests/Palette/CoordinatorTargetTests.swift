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

  /// 空の folders.json を一時パスに向ける。
  /// why: 向けないと ADR-015 方式 C が利用者の実物の履歴を拾い、結果が環境で変わる。
  private func withEmptyFolderHistory(_ body: (URL) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vox-chosen-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previous = FolderHistoryStore.path
    FolderHistoryStore.path = directory.appendingPathComponent("folders.json").path
    defer {
      FolderHistoryStore.path = previous
      try? FileManager.default.removeItem(at: directory)
    }
    try await body(directory)
  }

  @Test("選び直したフォルダは開き直しても続き、録音の後片付けで自動解決に戻る")
  func aChosenFolderSurvivesReopeningAndIsClearedByReset() async throws {
    // 自動解決でリポジトリを走査させない（決まらない回を「特定できず」にする）。
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory }

    try await withEmptyFolderHistory { directory in
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
      #expect(
        !coordinator.paletteModel.targetUnresolved,
        "選び直した対象で開き直したらヘッダを「特定できず」にした")
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
  }

  /// ADR-015 方式 C。`--repo` が無い回は最近使ったフォルダに落ち、前面アプリ由来ではないので
  /// ヘッダは「特定できず」のまま。
  @Test("最近使ったフォルダに落ちた回は source が recent で、ヘッダは特定できず")
  func anAutomaticFallbackToTheRecentFolderStaysUnresolved() async throws {
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory }

    try await withEmptyFolderHistory { directory in
      let recent = directory.appendingPathComponent("recent")
      try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
      FolderHistoryStore.record(recent.path, at: Date(timeIntervalSince1970: 1_700_000_000))

      let log = Box()
      let coordinator = PaletteCoordinator(hud: HudPanel())
      sources(of: coordinator, into: log)
      coordinator.open(atMilliseconds: 0, typedAt: nil)
      await waitForSource(log, count: 1)
      #expect(log.values == ["recent"], "最近使ったフォルダに落ちていない: \(log.values)")
      #expect(
        coordinator.paletteModel.target?.root == recent.path,
        "落ちた先が最近使ったフォルダではない")
      #expect(
        coordinator.paletteModel.targetUnresolved,
        "自動で落ちた回のヘッダを「特定できた」にした")
      coordinator.close(insert: nil, fileNameOnly: false)
    }
  }

  @Test("esc はフォルダ選択モードを抜けてから、次の esc でパレットを閉じる")
  func escapeLeavesTheFolderPickerBeforeClosingThePalette() {
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory }

    let coordinator = PaletteCoordinator(hud: HudPanel())
    coordinator.open(atMilliseconds: 0, typedAt: nil)
    coordinator.paletteModel.setPickingFolder(true)

    coordinator.escape()
    #expect(coordinator.isOpen, "フォルダ選択モードの esc でパレットを閉じた")
    #expect(!coordinator.paletteModel.isPickingFolder, "esc でモードを抜けていない")

    coordinator.escape()
    #expect(!coordinator.isOpen, "ファイル検索の esc でパレットを閉じていない")
  }
}

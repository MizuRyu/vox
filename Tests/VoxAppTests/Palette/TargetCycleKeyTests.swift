// T38-c 検索対象の巡回キー（⌘]）。キーの見分けと、巡回する候補の並び、
// 押すたびに次の候補へ移ることを見る。輪の順そのものは VoxCore の TargetCycleTests。

import AppKit
import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 検索対象の巡回キー")
struct TargetCycleKeyTests {
  private func event(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: 30)!
  }

  private func at(_ offset: Double) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
  }

  @Test("⌘] だけを巡回キーとして受ける")
  func onlyCommandBracketCyclesTheTarget() {
    #expect(PaletteKeys.isCycleTarget(event("]", .command)), "⌘] を受けていない")
    let others: [(String, NSEvent.ModifierFlags)] = [
      ("]", []), ("]", .control), ("]", .option), ("]", [.command, .shift]), ("[", .command)
    ]
    for (characters, modifiers) in others {
      #expect(
        !PaletteKeys.isCycleTarget(event(characters, modifiers)),
        "\(modifiers)\(characters) を巡回キーとして受けた")
    }
  }

  @Test("巡回する候補は worktree → 最近使ったフォルダの順で、検索中と Tree でも変わらない")
  func theCycleUsesTheSameCandidatesInEveryView() {
    let model = PaletteModel()
    model.resolvingTarget = false
    model.target = PaletteTarget(root: "/repos/vox", source: .orca)
    model.files = [IndexedFile(path: "a.txt")]
    model.refreshRows()
    model.setWorktrees([WorktreeCandidate(path: "/work/feature", branch: "feature")])
    model.setFolderHistory(
      FolderHistory(
        entries: [
          FolderHistoryEntry(path: "/repos/vox", lastUsedAt: at(50), useCount: 4),
          FolderHistoryEntry(path: "/repos/alpha", lastUsedAt: at(40), useCount: 3),
          FolderHistoryEntry(path: "/repos/bravo", lastUsedAt: at(30), useCount: 2)
        ]))
    let expected = ["/work/feature", "/repos/alpha", "/repos/bravo"]
    #expect(model.cycleTargets.map(\.root) == expected, "既定表示の輪が違う: \(model.cycleTargets)")
    #expect(
      model.cycleTargets.map(\.source) == [.worktree, .recent, .recent],
      "候補の source が違う: \(model.cycleTargets.map(\.source))")

    model.query = "a"
    model.refreshRows()
    #expect(model.targetRows.isEmpty, "検索中に候補行が出ている")
    #expect(model.cycleTargets.map(\.root) == expected, "検索中に輪が変わった: \(model.cycleTargets)")

    model.query = ""
    model.refreshRows()
    model.setFileViewMode(.tree)
    #expect(model.cycleTargets.map(\.root) == expected, "Tree 表示で輪が変わった: \(model.cycleTargets)")
  }

  @Test("同じフォルダが worktree 候補と履歴の両方にあっても輪には 1 度だけ出る")
  func theCycleKeepsEachFolderOnce() {
    let model = PaletteModel()
    model.resolvingTarget = false
    model.target = PaletteTarget(root: "/repos/vox", source: .orca)
    model.setWorktrees([WorktreeCandidate(path: "/work/feature", branch: "feature")])
    model.setFolderHistory(
      FolderHistory(
        entries: [
          FolderHistoryEntry(path: "/work/feature/", lastUsedAt: at(40), useCount: 3),
          FolderHistoryEntry(path: "/repos/alpha", lastUsedAt: at(30), useCount: 2)
        ]))
    #expect(
      model.cycleTargets.map(\.root) == ["/work/feature", "/repos/alpha"],
      "同じフォルダが輪に二重に入っている: \(model.cycleTargets.map(\.root))")
    #expect(model.cycleTargets.first?.source == .worktree, "先に出た worktree 候補を落とした")
  }

  @Test("押すたびに次の候補へ移り、選び直した後は輪を写し直す")
  func cyclingWalksTheCandidatesAndIsRecapturedAfterAPick() async throws {
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    let previousPath = FolderHistoryStore.path
    defer {
      VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory
      FolderHistoryStore.path = previousPath
    }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vox-cycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    FolderHistoryStore.path = directory.appendingPathComponent("folders.json").path

    // 新しい順に charlie → bravo → alpha になる履歴を置く。
    var history = FolderHistory()
    var folders: [String] = []
    for (offset, name) in ["alpha", "bravo", "charlie"].enumerated() {
      let folder = directory.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      history.record(folder.path, at: at(Double(offset)))
      folders.append(folder.path)
    }
    try history.encoded().write(to: URL(fileURLWithPath: FolderHistoryStore.path))

    let coordinator = PaletteCoordinator(hud: HudPanel(), indexes: ResidentIndexStore())
    coordinator.open(atMilliseconds: 0, typedAt: nil)
    for _ in 0..<500 {
      if coordinator.paletteModel.folderHistory.entries.count == 3 { break }
      try? await Task.sleep(for: .milliseconds(2))
    }
    // ADR-015: 対応していないアプリでは最近使ったフォルダの先頭（charlie）に解決される。
    let charlie = folders[2]
    let bravo = folders[1]
    let alpha = folders[0]
    #expect(coordinator.paletteModel.target?.root == charlie, "最近使ったフォルダの先頭に解決していない")

    // 輪は候補（bravo → alpha）を巡り、押し始めの対象（charlie）を経て一周する。
    var visited: [String?] = []
    for _ in 0..<4 {
      coordinator.cycleTarget()
      visited.append(coordinator.paletteModel.target?.root)
    }
    #expect(
      visited == [bravo, alpha, charlie, bravo],
      "輪を一周して先頭に戻っていない: \(visited)")

    // 候補行から選び直したら、次の打鍵はそのときの候補から写し直す。
    coordinator.switchTarget(to: PaletteTarget(root: alpha, source: .recent))
    coordinator.cycleTarget()
    // alpha を選んだ後の候補は charlie → bravo なので、次の打鍵で charlie。
    #expect(
      coordinator.paletteModel.target?.root == charlie,
      "選び直した後に輪を写し直していない: \(coordinator.paletteModel.target?.root ?? "-")")
    coordinator.close(insert: nil, fileNameOnly: false)
    coordinator.reset()
  }

  @Test("候補が無ければ巡回キーは何も変えない")
  func cyclingWithoutCandidatesChangesNothing() {
    let previousPath = FolderHistoryStore.path
    FolderHistoryStore.path = NSTemporaryDirectory() + "vox-empty-\(UUID().uuidString).json"
    defer { FolderHistoryStore.path = previousPath }
    let coordinator = PaletteCoordinator(hud: HudPanel(), indexes: ResidentIndexStore())
    coordinator.open(atMilliseconds: 0, typedAt: nil)
    coordinator.cycleTarget()
    #expect(coordinator.paletteModel.target == nil, "候補が無いのに対象が変わった")
    coordinator.close(insert: nil, fileNameOnly: false)
    coordinator.reset()
  }
}

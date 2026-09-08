// パレットの内容のリセット。閉じるときと検索対象を切り替えるときの両方が通る。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 内容のリセット")
struct ModelResetTests {
  @Test("リセットは検索結果だけを空にし、対象と入力は呼び出し側に残す")
  func resetClearsOnlyTheContents() {
    let model = PaletteModel()
    model.target = PaletteTarget(root: "/tmp/vox", source: .worktree)
    model.sigil = .symbol
    model.query = "View"
    model.committedTail = "確定済み"
    model.files = [IndexedFile(path: "Sources/UI/View.swift")]
    model.refreshRows()
    model.setWorktrees([WorktreeCandidate(path: "/tmp/other", branch: "topic")])
    model.setFileViewMode(.tree)
    model.preview = FilePreview(title: "View.swift", detail: "", lines: ["x"], notice: nil)
    model.changedCount = 3
    model.totalCount = 9

    model.reset()

    #expect(model.files.isEmpty && model.rows.isEmpty && model.treeRows.isEmpty, "索引が残った")
    #expect(model.worktrees.isEmpty, "worktree 候補が残った")
    #expect(model.preview == nil, "プレビューが残った")
    #expect(model.changedCount == 0 && model.totalCount == 0, "件数が残った")
    #expect(model.fileViewMode == .changes, "表示が Changes に戻っていない")
    #expect(model.selection == model.defaultSelection, "選択が既定に戻っていない")
    // 対象・sigil・クエリ・挿入先の末尾は呼び出し側が決める。閉じるときは nil と空に、
    // 切り替えるときは新しい対象に置く。どちらの値を選ぶかはここでは決めない。
    #expect(
      model.target?.root == "/tmp/vox" && model.sigil == .symbol && model.query == "View"
        && model.committedTail == "確定済み", "呼び出し側の決めた値まで消した")
  }
}

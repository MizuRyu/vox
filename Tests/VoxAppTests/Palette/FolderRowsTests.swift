// T23 検索対象を切り替える候補行（worktree 候補と最近使ったフォルダ）と、
// ヘッダのクリックで入るフォルダ選択モード。選択インデックスが 1 つの空間で数えられているか。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 検索対象の切り替え")
struct FolderRowsTests {
  private func at(_ offset: Double) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
  }

  /// 検索対象は `/repos/vox`。履歴には対象自身も入っている（候補からは外れる）。
  private func model() -> PaletteModel {
    let model = PaletteModel()
    model.resolvingTarget = false
    model.target = PaletteTarget(root: "/repos/vox", source: .orca)
    model.files = [
      IndexedFile(path: "a.txt"), IndexedFile(path: "Sources/App.swift"),
      IndexedFile(path: "z.txt")
    ]
    model.refreshRows()
    model.setFolderHistory(
      FolderHistory(
        entries: [
          FolderHistoryEntry(path: "/repos/vox", lastUsedAt: at(50), useCount: 4),
          FolderHistoryEntry(path: "/repos/alpha", lastUsedAt: at(40), useCount: 3),
          FolderHistoryEntry(path: "/repos/bravo", lastUsedAt: at(30), useCount: 2),
          FolderHistoryEntry(path: "/repos/charlie", lastUsedAt: at(20), useCount: 1),
          FolderHistoryEntry(path: "/work/delta", lastUsedAt: at(10), useCount: 1)
        ]))
    return model
  }

  // MARK: 既定表示の候補行

  @Test("最近使ったフォルダは Changes でクエリが空のときだけ、先頭 3 件出る")
  func recentFoldersAppearOnlyInChangesWithAnEmptyQuery() {
    let model = model()
    #expect(
      model.targetRows.map(\.id)
        == ["folder:/repos/alpha", "folder:/repos/bravo", "folder:/repos/charlie"],
      "既定表示の候補が違う: \(model.targetRows.map(\.id))")

    model.query = "a"
    model.refreshRows()
    #expect(model.targetRows.isEmpty, "検索中に候補を出した: \(model.targetRows.map(\.id))")

    model.query = ""
    model.refreshRows()
    model.setFileViewMode(.tree)
    #expect(model.targetRows.isEmpty, "Tree 表示に候補を出した: \(model.targetRows.map(\.id))")
  }

  @Test("履歴が空なら候補行は出ず、既定の選択はファイルの先頭のまま")
  func anEmptyHistoryLeavesTheDefaultAppearance() {
    let model = model()
    model.setFolderHistory(FolderHistory())
    #expect(model.targetRows.isEmpty, "履歴が空でも候補が出た: \(model.targetRows.map(\.id))")
    #expect(model.defaultSelection == 0, "既定の選択がファイルの先頭でない: \(model.defaultSelection)")
  }

  @Test("worktree 候補を先に並べ、既定の選択はどちらの候補よりも後のファイル行")
  func worktreeCandidatesComeBeforeRecentFolders() {
    let model = model()
    model.setWorktrees([WorktreeCandidate(path: "/repos/vox-wt", branch: "topic")])
    #expect(
      model.targetRows.map(\.id) == [
        "worktree:/repos/vox-wt", "folder:/repos/alpha", "folder:/repos/bravo",
        "folder:/repos/charlie"
      ],
      "候補の並びが違う: \(model.targetRows.map(\.id))")
    #expect(model.defaultSelection == 4, "既定の選択がファイルの先頭でない: \(model.defaultSelection)")
    model.selection = model.defaultSelection
    #expect(model.selectedRow?.file.path == "a.txt", "候補の次がファイルの先頭行になっていない")
    #expect(model.selectedDisplayID == "changes:a.txt", "スクロール先がファイル行を指していない")
  }

  @Test("履歴・索引・worktree がどの順に届いても、既定の選択はファイルの先頭")
  func theDefaultSelectionStaysOnTheFirstFileWhateverArrivesFirst() {
    // パレットを開いた直後の実際の順序（索引より先に履歴が届く）を再現する。
    let model = PaletteModel()
    model.target = PaletteTarget(root: "/repos/vox", source: .orca)
    model.setFolderHistory(
      FolderHistory(entries: [
        FolderHistoryEntry(path: "/repos/alpha", lastUsedAt: at(40), useCount: 1),
        FolderHistoryEntry(path: "/repos/bravo", lastUsedAt: at(30), useCount: 1),
        FolderHistoryEntry(path: "/repos/charlie", lastUsedAt: at(20), useCount: 1)
      ]))
    model.files = [IndexedFile(path: "a.txt"), IndexedFile(path: "z.txt")]
    model.refreshRows()
    #expect(model.selectedRow?.file.path == "a.txt", "索引が届いた後もファイルの先頭にいない")

    model.setWorktrees([WorktreeCandidate(path: "/repos/vox-wt", branch: "topic")])
    #expect(
      model.selectedRow?.file.path == "a.txt",
      "worktree が届いて選択が候補に吸い寄せられた: \(String(describing: model.selectedDisplayID))")
  }

  @Test("候補行を選んでいる間に worktree が先頭へ入っても、同じ候補のまま")
  func aSelectedCandidateSurvivesLaterCandidates() {
    let model = model()
    model.select(0)
    #expect(model.selectedTargetRow?.id == "folder:/repos/alpha", "前提の選択が違う")
    model.setWorktrees([WorktreeCandidate(path: "/repos/vox-wt", branch: "topic")])
    #expect(
      model.selectedTargetRow?.id == "folder:/repos/alpha",
      "先に届いた候補の前に別の候補が入って選択がずれた: \(String(describing: model.selectedTargetRow?.id))")
  }

  @Test("Tree 表示からフォルダ選択モードに入ると候補一覧に戻す")
  func theFolderPickerLeavesTheTreeDisplay() {
    let model = model()
    model.setFileViewMode(.tree)
    model.setPickingFolder(true)
    #expect(
      model.fileViewMode == .changes,
      "Tree のままではファイル行を描いたままフォルダを選ぶことになる")
    #expect(model.targetRows.last?.id == "choose", "「フォルダを選ぶ」が出ていない")
    model.selection = model.defaultSelection
    #expect(model.selectedTargetRow?.id == "folder:/repos/alpha", "先頭のフォルダを選んでいない")
  }

  @Test("候補が索引より後に届いても、選んでいたファイル行は動かない")
  func lateCandidatesKeepTheSelectedFile() {
    let model = model()
    model.setFolderHistory(FolderHistory())
    model.selection = 1
    #expect(model.selectedRow?.file.path == "Sources/App.swift", "前提の選択が違う")
    model.setFolderHistory(
      FolderHistory(entries: [
        FolderHistoryEntry(path: "/repos/alpha", lastUsedAt: at(40), useCount: 1)
      ]))
    #expect(
      model.selectedRow?.file.path == "Sources/App.swift",
      "候補が挿入されて選択が動いた: \(String(describing: model.selectedRow?.file.path))")
  }

  // MARK: 候補行の確定

  @Test("候補行の Enter は検索対象を切り替え、パスは挿入しない")
  func committingACandidateSwitchesTheTargetWithoutInserting() {
    let model = model()
    model.setWorktrees([WorktreeCandidate(path: "/repos/vox-wt", branch: "topic")])
    var inserted: [String] = []
    var switched: [PaletteTarget] = []
    model.onCommit = { path, _ in inserted.append(path) }
    model.onSwitchTarget = { switched.append($0) }

    model.select(0)
    model.commit(fileNameOnly: false)
    #expect(
      switched == [PaletteTarget(root: "/repos/vox-wt", source: .worktree)],
      "worktree 行の切り替えが違う: \(switched)")

    model.select(1)
    // ⌥Enter でも挿入ではなく切り替え（フォルダはファイル名のみを持たない）。
    model.commit(fileNameOnly: true)
    #expect(
      switched.last == PaletteTarget(root: "/repos/alpha", source: .recent),
      "フォルダ行の切り替えが違う: \(String(describing: switched.last))")
    #expect(inserted.isEmpty, "候補行でパスを挿入した: \(inserted)")
  }

  // MARK: フォルダ選択モード

  @Test("フォルダ選択モードは最近使ったフォルダと『フォルダを選ぶ』だけを出す")
  func theFolderPickerShowsOnlyFoldersAndThePanelEntry() {
    let model = model()
    model.setPickingFolder(true)
    #expect(
      model.targetRows.map(\.id) == [
        "folder:/repos/alpha", "folder:/repos/bravo", "folder:/repos/charlie",
        "folder:/work/delta", "choose"
      ],
      "フォルダ選択モードの候補が違う: \(model.targetRows.map(\.id))")
    #expect(model.defaultSelection == 0, "既定の選択が先頭のフォルダでない: \(model.defaultSelection)")
    model.selection = model.defaultSelection
    #expect(model.selectedRow == nil, "フォルダ選択モードでファイル行を選べる")
    #expect(model.fieldSigil == "~", "検索フィールドの記号が `~` でない: \(model.fieldSigil)")
  }

  @Test("フォルダ選択モードで打った文字はフォルダを絞る")
  func typingInTheFolderPickerNarrowsFolders() {
    let model = model()
    model.setPickingFolder(true)
    model.query = "work"
    model.refreshRows()
    #expect(
      model.targetRows.map(\.id) == ["folder:/work/delta", "choose"],
      "打った文字で絞れていない: \(model.targetRows.map(\.id))")
  }

  @Test("フォルダ選択モードを抜けるとクエリが空に戻り、ファイル行が戻る")
  func leavingTheFolderPickerRestoresTheFileSearch() {
    let model = model()
    model.setPickingFolder(true)
    model.query = "work"
    model.refreshRows()
    model.setPickingFolder(false)
    #expect(!model.isPickingFolder, "モードを抜けていない")
    #expect(model.query.isEmpty, "クエリが空に戻っていない: \(model.query)")
    #expect(model.fieldSigil == "@", "記号がファイル検索に戻っていない: \(model.fieldSigil)")
    model.selection = model.defaultSelection
    #expect(model.selectedRow?.file.path == "a.txt", "ファイル行が戻っていない")
  }

  @Test("『フォルダを選ぶ』の Enter は選択パネルの導線だけを呼ぶ")
  func committingTheChooseRowOnlyAsksForThePanel() {
    let model = model()
    var chose = 0
    var switched: [PaletteTarget] = []
    var inserted: [String] = []
    model.onChooseFolder = { chose += 1 }
    model.onSwitchTarget = { switched.append($0) }
    model.onCommit = { path, _ in inserted.append(path) }

    model.setPickingFolder(true)
    model.select(model.targetRows.count - 1)
    model.commit(fileNameOnly: false)
    #expect(chose == 1, "選択パネルの導線が呼ばれていない: \(chose)")
    #expect(switched.isEmpty && inserted.isEmpty, "導線の行で切り替えか挿入が起きた")
  }
}

// コマンドパレット（M3）。docs/mock.html 状態 2 の要素と配置を SwiftUI で再現する
// （配色・書体の完全再現は範囲外）。
//
// HUD と同じく `.nonactivatingPanel` で、**`NSApp.activate` は呼ばず `makeKey()` だけ**する
// （前面アプリを変えない。ADR-011）。閉じるときに key を返して HUD に戻す。
//
// キーは検索フィールドの field editor 経由で受ける（↑↓ / Enter / ⌥Enter）。
// `esc` だけは録音中の CGEventTap が飲んでいるので、VoxController から閉じる。

import AppKit
import SwiftUI
import VoxCore

@MainActor
final class PaletteModel: ObservableObject {
  enum FileViewMode: String, CaseIterable {
    case changes = "Changes"
    case tree = "Tree"
  }

  /// 検索対象。解決前は nil で、ヘッダに「検索対象を確認中」を出す。
  @Published var target: PaletteTarget?
  /// アダプタもフォールバックも失敗した。ヘッダに「対象を特定できず」を出す。
  @Published var targetUnresolved = false
  @Published var resolvingTarget = true
  @Published var sigil: PaletteSigil = .file
  @Published var query = ""
  @Published var rows: [PaletteRow] = []
  @Published var treeRows: [FileTreeRow] = []
  /// T38-a。同一リポジトリの他の worktree。ファイル行の上に候補として並べる。
  @Published var worktrees: [WorktreeCandidate] = []
  @Published var fileViewMode: FileViewMode = .changes
  @Published var selection = 0
  @Published var preview: FilePreview?
  @Published var changedCount = 0
  @Published var totalCount = 0
  /// 挿入先プレビューに出す committed の末尾。
  @Published var committedTail = ""
  /// 検索フィールドにフォーカスを取り直す合図（HUD と同じ手）。
  @Published var focusToken = 0
  /// T22。コピー直後の 1.2 秒だけ右ペインのヘッダを「コピーしました」にする。
  @Published var copiedNotice = false

  private var copyNoticeTask: Task<Void, Never>?

  /// 索引の全件。検索のたびにここから絞る。
  var files: [IndexedFile] = [] {
    didSet { fileTree = FileTree(files: files) }
  }
  private var fileTree = FileTree(files: [])
  private var expandedDirectories = Set<String>()

  /// Enter（`fileNameOnly` は ⌥Enter）。
  var onCommit: ((_ path: String, _ fileNameOnly: Bool) -> Void)?
  /// esc 相当（キーヒントの `Esc` をクリックしたとき）。未接続なら何もしない。
  var onCancel: (() -> Void)?
  /// T38-a。worktree 行を選んだ。検索対象の切り替えは App 側が行う。
  var onSwitchTarget: ((WorktreeCandidate) -> Void)?

  /// 候補行は Changes・クエリが空のときだけ出す（Tree と検索中はファイルだけ並べる）。
  var visibleWorktrees: [WorktreeCandidate] {
    fileViewMode == .changes && query.isEmpty ? worktrees : []
  }

  /// 選択中の worktree 行。ファイル行を選んでいるときは nil。
  var selectedWorktree: WorktreeCandidate? {
    let candidates = visibleWorktrees
    guard selection >= 0, selection < candidates.count else { return nil }
    return candidates[selection]
  }

  var selectedRow: PaletteRow? {
    if fileViewMode == .tree {
      guard selection >= 0, selection < treeRows.count, let file = treeRows[selection].file else {
        return nil
      }
      return PaletteRow(file: file)
    }
    let index = selection - visibleWorktrees.count
    guard index >= 0, index < rows.count else { return nil }
    return rows[index]
  }

  var selectedDisplayID: String? {
    if fileViewMode == .tree {
      guard treeRows.indices.contains(selection) else { return nil }
      return "tree:" + treeRows[selection].id
    }
    if let candidate = selectedWorktree { return "worktree:" + candidate.path }
    let index = selection - visibleWorktrees.count
    guard rows.indices.contains(index) else { return nil }
    return "changes:" + rows[index].file.path
  }

  /// 既定の選択位置。候補行は先頭に積むので、既定はその次（＝ファイルの先頭行）。
  /// 選択を初期化する箇所はすべてここを使う。
  var defaultSelection: Int { visibleWorktrees.count }

  /// 候補は索引より後に届く。挿入した分だけ選択を下げ、選んでいた行を動かさない。
  func setWorktrees(_ candidates: [WorktreeCandidate]) {
    let before = visibleWorktrees.count
    worktrees = candidates
    let inserted = visibleWorktrees.count - before
    if inserted != 0, selection >= before {
      selection = max(0, selection + inserted)
    }
    clampSelection()
  }

  func refreshRows() {
    rows = FileIndex.rows(query: query, in: files)
    refreshTreeRows()
  }

  func setFileViewMode(_ mode: FileViewMode) {
    guard fileViewMode != mode else { return }
    fileViewMode = mode
    selection = defaultSelection
    clampSelection()
    preview = nil
  }

  /// 索引・候補・選択・プレビューを空にする。検索対象と sigil / クエリは呼び出し側が決める
  /// （閉じるときは空に戻し、対象を切り替えるときは新しい対象を先に置く）。
  func reset() {
    files = []
    rows = []
    worktrees = []
    resetFileView()
    selection = defaultSelection
    preview = nil
    changedCount = 0
    totalCount = 0
  }

  func resetFileView() {
    fileViewMode = .changes
    expandedDirectories.removeAll()
    fileTree = FileTree(files: [])
    treeRows = []
  }

  private func refreshTreeRows(preservingID: String? = nil) {
    treeRows = fileTree.rows(query: query, expandedDirectories: expandedDirectories)
    if let preservingID, let index = treeRows.firstIndex(where: { $0.id == preservingID }) {
      selection = index
    }
    clampSelection()
  }

  private var visibleCount: Int {
    fileViewMode == .tree ? treeRows.count : visibleWorktrees.count + rows.count
  }

  private func clampSelection() {
    selection = visibleCount == 0 ? 0 : max(0, min(selection, visibleCount - 1))
    if selectedRow == nil { preview = nil }
  }

  func move(by delta: Int) {
    guard visibleCount > 0 else { return }
    selection = max(0, min(visibleCount - 1, selection + delta))
    if selectedRow == nil { preview = nil }
  }

  /// マウスで行を選ぶ。状態は selection だけ（キーと同じ経路）。
  /// 併せて検索フィールドにフォーカスを戻し、クリックの後もキー操作を続けられるようにする。
  func select(_ index: Int) {
    guard index >= 0, index < visibleCount else { return }
    selection = index
    if selectedRow == nil { preview = nil }
    focusToken += 1
  }

  func commit(fileNameOnly: Bool) {
    // T38-a。worktree 行は挿入せず検索対象を切り替える（⌥Enter でも同じ）。
    if let candidate = selectedWorktree {
      onSwitchTarget?(candidate)
      return
    }
    if fileViewMode == .tree, selection >= 0, selection < treeRows.count,
      treeRows[selection].kind == .directory {
      toggleDirectory(at: selection)
      return
    }
    guard let row = selectedRow else { return }
    onCommit?(row.file.path, fileNameOnly)
  }

  func toggleDirectory(at index: Int) {
    guard query.isEmpty, index >= 0, index < treeRows.count,
      treeRows[index].kind == .directory
    else { return }
    let row = treeRows[index]
    if expandedDirectories.contains(row.path) {
      expandedDirectories.remove(row.path)
    } else {
      expandedDirectories.insert(row.path)
    }
    refreshTreeRows(preservingID: row.id)
    preview = nil
  }

  func cancel() {
    onCancel?()
  }

  /// T22。右ペインに出ているプレビューの全文（notice があればその 1 行を頭に足す）。
  var previewText: String {
    guard let preview else { return "" }
    var lines: [String] = []
    if let notice = preview.notice { lines.append(notice) }
    lines.append(contentsOf: preview.lines)
    return lines.joined(separator: "\n")
  }

  /// T22。プレビュー全文をコピーする。**`NSPasteboard.general` に直接書く**。
  /// vox の挿入経路（promise pasteboard）とは無関係で、退避も復元もしない。
  func copyPreview() {
    let text = previewText
    guard !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    showCopiedNotice()
  }

  func showCopiedNotice() {
    copiedNotice = true
    copyNoticeTask?.cancel()
    copyNoticeTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1200))
      guard !Task.isCancelled else { return }
      copiedNotice = false
    }
  }

  func clearCopiedNotice() {
    copyNoticeTask?.cancel()
    copyNoticeTask = nil
    copiedNotice = false
  }
}

/// HUD と同じ理由で canBecomeKey を上書きする（borderless は既定で key になれない）。
private final class VoxPalettePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class PalettePanel {
  let model = PaletteModel()
  private let panel: VoxPalettePanel

  init() {
    panel = VoxPalettePanel(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = false

    let hosting = NSHostingView(rootView: PaletteView(model: model))
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = 14
    hosting.layer?.masksToBounds = true
    panel.contentView = hosting
  }

  var isVisible: Bool { panel.isVisible }

  func reset(committedTail: String) {
    model.target = nil
    model.targetUnresolved = false
    model.resolvingTarget = true
    model.sigil = .file
    model.query = ""
    model.reset()
    model.committedTail = committedTail
    model.clearCopiedNotice()
  }

  func show() {
    reposition()
    // HUD と同じ。NSApp.activate は呼ばない（前面アプリを変えない）。
    panel.orderFrontRegardless()
    panel.makeKey()
    model.focusToken += 1
  }

  func hide() {
    panel.makeFirstResponder(nil)
    panel.resignKey()
    panel.orderOut(nil)
  }

  private func reposition() {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let width = min(860, visible.width - 80)
    let height = min(520, visible.height - 120)
    let origin = NSPoint(
      x: visible.midX - width / 2,
      y: visible.midY - height / 2)
    panel.setFrame(
      NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
  }
}

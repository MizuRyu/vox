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

  /// 検索対象を切り替える行。worktree 候補（T38-a）と最近使ったフォルダ（T23）、
  /// フォルダ選択パネルの導線を 1 つの並びで数える（選択を 1 つの空間で扱うため）。
  enum TargetRow: Equatable {
    case worktree(WorktreeCandidate)
    case folder(FolderHistoryEntry)
    /// `NSOpenPanel` を開く導線。履歴に無いフォルダを初めて指定するとき。
    case chooseFolder

    var id: String {
      switch self {
      case .worktree(let candidate): "worktree:" + candidate.path
      case .folder(let entry): "folder:" + entry.path
      case .chooseFolder: "choose"
      }
    }
  }

  /// 既定表示で出す最近使ったフォルダの件数（T23）。
  static let recentFolderLimit = 3

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
  @Published private(set) var worktrees: [WorktreeCandidate] = []
  /// T23。最近使ったフォルダ。worktree 候補の後に並べる。
  @Published private(set) var folderHistory = FolderHistory()
  /// T23。ヘッダのパスをクリックして入るフォルダ選択モード。候補はフォルダだけになる。
  @Published private(set) var isPickingFolder = false
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
  /// T38-a / T23。候補行を選んだ。検索対象の切り替えは App 側が行う。
  var onSwitchTarget: ((PaletteTarget) -> Void)?
  /// T23。「フォルダを選ぶ」を選んだ。`NSOpenPanel` を開くのは App 側。
  var onChooseFolder: (() -> Void)?

  /// 検索対象を切り替える候補行。フォルダ選択モードではフォルダだけ、通常は Changes で
  /// クエリが空のときだけ出す（Tree と検索中はファイルだけ並べる）。
  var targetRows: [TargetRow] {
    if isPickingFolder {
      return folders(matching: query, limit: FolderHistory.limit).map(TargetRow.folder)
        + [.chooseFolder]
    }
    guard fileViewMode == .changes, query.isEmpty else { return [] }
    return worktrees.map(TargetRow.worktree)
      + folders(matching: "", limit: Self.recentFolderLimit).map(TargetRow.folder)
  }

  /// 選択中の候補行。ファイル行を選んでいるときは nil。
  var selectedTargetRow: TargetRow? {
    let candidates = targetRows
    guard selection >= 0, selection < candidates.count else { return nil }
    return candidates[selection]
  }

  var selectedRow: PaletteRow? {
    // T23。フォルダ選択モードにはファイル行が無い。
    guard !isPickingFolder else { return nil }
    if fileViewMode == .tree {
      guard selection >= 0, selection < treeRows.count, let file = treeRows[selection].file else {
        return nil
      }
      return PaletteRow(file: file)
    }
    let index = selection - targetRows.count
    guard index >= 0, index < rows.count else { return nil }
    return rows[index]
  }

  var selectedDisplayID: String? {
    if let candidate = selectedTargetRow { return candidate.id }
    guard !isPickingFolder else { return nil }
    if fileViewMode == .tree {
      guard treeRows.indices.contains(selection) else { return nil }
      return "tree:" + treeRows[selection].id
    }
    let index = selection - targetRows.count
    guard rows.indices.contains(index) else { return nil }
    return "changes:" + rows[index].file.path
  }

  /// 既定の選択位置。候補行は先頭に積むので、既定はその次（＝ファイルの先頭行）。
  /// フォルダ選択モードはファイル行が無いので先頭の候補。選択を初期化する箇所はすべてここを使う。
  var defaultSelection: Int { isPickingFolder ? 0 : targetRows.count }

  /// T23。検索フィールドに出す記号。フォルダ選択モードだけ `~`（sigil の割り当ては変えない）。
  var fieldSigil: String {
    isPickingFolder ? PaletteSigil.branch.rawValue : sigil.rawValue
  }

  /// 候補は索引より後に届く。挿入した分だけ選択を下げ、選んでいた行を動かさない。
  func setWorktrees(_ candidates: [WorktreeCandidate]) {
    adjustingTargetRows { worktrees = candidates }
  }

  func setFolderHistory(_ history: FolderHistory) {
    adjustingTargetRows { folderHistory = history }
  }

  private func adjustingTargetRows(_ change: () -> Void) {
    let before = targetRows.count
    change()
    let inserted = targetRows.count - before
    if inserted != 0, selection >= before {
      selection = max(0, selection + inserted)
    }
    clampSelection()
  }

  private func folders(matching query: String, limit: Int) -> [FolderHistoryEntry] {
    folderHistory.candidates(matching: query, excluding: target?.root, limit: limit)
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
  /// 最近使ったフォルダは対象を切り替えても出し続けるので、ここでは消さない（T23）。
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
    if isPickingFolder { return targetRows.count }
    return fileViewMode == .tree ? treeRows.count : targetRows.count + rows.count
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
    // T38-a / T23。候補行は挿入せず検索対象を切り替える（⌥Enter でも同じ）。
    if let candidate = selectedTargetRow {
      switch candidate {
      case .worktree(let worktree):
        onSwitchTarget?(PaletteTarget(root: worktree.path, source: .worktree))
      case .folder(let entry):
        onSwitchTarget?(PaletteTarget(root: entry.path, source: .recent))
      case .chooseFolder:
        onChooseFolder?()
      }
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

  /// T23。ヘッダのパスのクリックで入り、esc で抜ける。クエリはどちらの向きも空から始める。
  func setPickingFolder(_ picking: Bool) {
    guard isPickingFolder != picking else { return }
    isPickingFolder = picking
    query = ""
    refreshRows()
    selection = defaultSelection
    clampSelection()
    preview = nil
    focusToken += 1
  }

  /// T23。esc をフォルダ選択モードが受け取ったか。受け取ったらパレットは閉じない。
  func consumeEscape() -> Bool {
    guard isPickingFolder else { return false }
    setPickingFolder(false)
    return true
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
    // T23。履歴は開くたびに読み直す。フォルダ選択モードも毎回ファイル検索から始める。
    model.setFolderHistory(FolderHistory())
    model.setPickingFolder(false)
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

// M3 コマンドパレット。開閉と検索対象の解決、索引とプレビューの読み込みを持つ。
// 録音状態は持たない（開いてよいかの判定は VoxController 側）。
//   T22 パレット表示中も音声供給は止めない。開いた時点の淡色だけ締め、差し込みは閉じる時点の末尾

import AppKit
import Foundation
import VoxCore

@MainActor
final class PaletteCoordinator {
  /// 録音セッションの計測に足す出来事。値は VoxController が MetricsSession に書く。
  enum Metric {
    case opened
    case targetResolved(String?)
    case closed(openMilliseconds: Double?)
  }

  private let panel = PalettePanel()
  private let hud: HudPanel
  /// T38-b。登録フォルダの常駐索引。未登録の対象では今までどおり開くたびに読む。
  private let indexes: ResidentIndexStore

  /// 開いた時点の tentative を final として締める。給餌ループとは別のタスクから呼ぶ（ADR-007）。
  var finalizeSegment: @MainActor () async -> Void = {}
  /// R16 で固定した挿入先。検索対象の解決に使う。
  var targetBundleIdentifier: @MainActor () -> String? = { nil }
  var onMetric: @MainActor (Metric) -> Void = { _ in }

  private(set) var isOpen = false
  /// 検査がパネルの状態を直に置く（本体はコールバックと下のメソッド越しに触る）。
  var paletteModel: PaletteModel { panel.model }
  /// 開いた直後に走らせる「tentative を締める」タスク。Enter を処理する前にこれを待つ
  /// （差し込む位置を動かさないため）。
  private var finalizeTask: Task<Void, Never>?
  /// 検索対象の解決と索引づくり。閉じるときに取り消す。
  private var setupTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var previewedPath: String?
  /// T22。パレットを開いた時刻。閉じるときに `palette_open_ms` を出す。
  private var openedAtMilliseconds: Double?
  /// T13。`@` を打った caret 位置。nil は「committed の末尾」（`⌃P` と、末尾で打った場合）。
  /// 末尾で打った回を位置で固定しないのは、開いたあとに締めた final が末尾に入るため。
  private var insertLocation: Int?
  /// T23。この録音の間だけ持ち越す、選び直した検索対象。開き直しても同じフォルダで続け、
  /// 録音の後片付け（`reset`）で捨てて自動解決に戻す。
  private var chosenTarget: PaletteTarget?
  /// T23。表示中のフォルダ選択パネル。esc と後片付けで閉じる。
  private var folderPanel: NSOpenPanel?
  /// T38-c。`⌘]` で巡回する輪。候補を選び直すと写し直す。
  private var cycle = TargetCycle(current: nil, candidates: [])

  init(hud: HudPanel, indexes: ResidentIndexStore) {
    self.hud = hud
    self.indexes = indexes
    panel.model.onCommit = { [weak self] path, fileNameOnly in
      self?.close(insert: path, fileNameOnly: fileNameOnly)
    }
    // T16。キーヒントの Esc クリック。esc キーと同じ「挿入せず再開」。
    panel.model.onCancel = { [weak self] in
      self?.close(insert: nil, fileNameOnly: false)
    }
    // T38-a / T23。候補行で選んだ worktree・フォルダに検索対象を移す。
    panel.model.onSwitchTarget = { [weak self] target in
      self?.switchTarget(to: target)
    }
    // T23。履歴に無いフォルダを選ぶ導線。
    panel.model.onChooseFolder = { [weak self] in
      self?.chooseFolder()
    }
    // T38-c。`⌘]` で候補を巡回する。
    panel.onCycleTarget = { [weak self] in
      self?.cycleTarget()
    }
  }

  /// `⌃P` と `@` の打鍵。T22 で**音声供給は止めない**（開いたまま喋り続けられる）。
  /// `typedAt` は `@` を打った caret 位置（`⌃P` は nil）。
  func open(atMilliseconds: Double, typedAt: Int?) {
    isOpen = true
    openedAtMilliseconds = atMilliseconds
    onMetric(.opened)
    // 末尾で打った場合は位置で固定しない（この後に喋った分の後ろ、閉じる時点の末尾が正しい）。
    let headEnd = (hud.model.head as NSString).length
    insertLocation = typedAt.flatMap { $0 >= headEnd ? nil : $0 }

    // 開いた時点の tentative を final として締める（淡色を残したまま閉じないため）。
    // T22。供給は止めないので、締めた後に届く final も通常どおり `head` に追記される。
    finalizeTask = Task { @MainActor in
      await finalizeSegment()
    }

    panel.reset(committedTail: String(hud.model.head.suffix(40)))
    // T38-c。候補は開くたびに読み直すので、輪も写し直す。
    resetCycle()
    // T22。録音は続いているので状態表示は「録音中」のまま。
    panel.show()
    voxLog("palette_opened at_ms=\(atMilliseconds)")

    setupTask = Task { @MainActor in
      // T23。最近使ったフォルダはファイル読み込みなので detached。候補行は索引より先に出る。
      let folders = Task.detached { FolderHistoryStore.load() }
      let repositories = VoxConfig.fallbackRepositories
      // T23。この録音で選び直したフォルダがあれば、自動解決に戻さない。
      let target: PaletteTarget?
      if let chosenTarget {
        target = chosenTarget
      } else {
        target = await PaletteTargetResolver.resolve(
          bundleIdentifier: targetBundleIdentifier(), fallbackRepositories: repositories)
      }
      // 計測は取り消し判定より先に入れる（早く閉じた回も何で解決したかは残す）。
      onMetric(.targetResolved(target?.source.rawValue))
      guard !Task.isCancelled else { return }
      panel.model.target = target
      panel.model.targetUnresolved = target == nil || target?.source == .fallback
      panel.model.resolvingTarget = false
      // T20。HUD にファイルをペーストしたときの相対パスの基準（未解決なら nil のまま）。
      hud.model.repositoryRoot = target?.root
      // 対象を置いた後に履歴を入れる（今の対象を候補から外すため）。
      panel.model.setFolderHistory(await folders.value)
      guard !Task.isCancelled else { return }

      guard let root = target?.root else { return }
      await loadContents(root: root)
    }
  }

  /// `Enter`（`insert` あり）と `esc`（nil）。**開いてからここまでが `palette_open_ms`**。
  func close(insert: String?, fileNameOnly: Bool) {
    guard isOpen else { return }
    let openMilliseconds = openedAtMilliseconds.map { voxNowMilliseconds() - $0 }
    openedAtMilliseconds = nil
    isOpen = false
    setupTask?.cancel()
    setupTask = nil
    previewTask?.cancel()
    previewTask = nil
    // T23。確定した回だけ、そのときの検索対象を最近使ったフォルダに記録する
    // （開いただけでは記録しない）。書き込みは detached で、確定の経路を待たせない。
    if insert != nil, let folder = panel.model.target?.root {
      Task.detached { FolderHistoryStore.record(folder) }
    }
    dismissFolderPanel()
    panel.hide()
    hud.makeKeyAgain()

    Task { @MainActor in
      // 締めた final が committed に入り切るのを待ってから差し込む。
      await awaitPendingFinalize()
      if let insert {
        let value = fileNameOnly ? PaletteInsertion.fileName(of: insert) : insert
        // T17 / T21 / T22。差し込み位置は全文（head + tentative + tail）のオフセットで決める。
        // 既定は**閉じる時点の**全体の末尾で、開いている間に喋った分の後ろに入る（時間順）。
        // `@` を `head` の途中で打った回だけその位置。
        let buffer = hud.model.transcript
        let location = insertLocation ?? buffer.length
        hud.model.requestInsertion(
          PaletteInsertion.insert(value, into: buffer.text, at: location))
      }
      insertLocation = nil
      // T22。給餌は止めていないので再開は要らない。状態表示も「録音中」のまま。
      onMetric(.closed(openMilliseconds: openMilliseconds))
      voxLog(
        "palette_closed open_ms=\(openMilliseconds ?? -1) "
          + "inserted=\(insert.map { voxLoggable(path: $0) } ?? "-")")
    }
  }

  /// 設定画面を閉じたときに key を返す。開閉はしない。
  func focus() {
    panel.show()
  }

  /// 確定はパレットを締めるタスクの後。差し込む位置を動かさないため。
  /// 待っている間に開き直された回は新しいタスクが置かれるので、無くなるまで待つ。
  func awaitPendingFinalize() async {
    while let task = finalizeTask {
      await task.value
      if finalizeTask == task { finalizeTask = nil }
    }
  }

  /// 録音セッションの後片付け。開いていなくても呼ばれる。
  func reset() {
    isOpen = false
    setupTask?.cancel()
    setupTask = nil
    previewTask?.cancel()
    previewTask = nil
    finalizeTask = nil
    previewedPath = nil
    insertLocation = nil
    openedAtMilliseconds = nil
    // T23。選び直したフォルダはこの録音までで、次の録音は自動解決から始める。
    chosenTarget = nil
    resetCycle()
    dismissFolderPanel()
    panel.hide()
  }

  /// 終了時。締めるタスクも含めて走っているものを全部止める。
  func cancelPendingWork() {
    finalizeTask?.cancel()
    setupTask?.cancel()
    previewTask?.cancel()
    dismissFolderPanel()
  }

  /// T38-a / T23。候補行やフォルダ選択で選び直した対象。輪は写し直す（T38-c）。
  func switchTarget(to target: PaletteTarget) {
    resetCycle()
    applyTarget(target)
  }

  private func resetCycle() {
    cycle = TargetCycle(current: nil, candidates: [])
  }

  /// T38-c。`⌘]`。候補を輪の順に進む。最初の打鍵で今の候補を写し取る。
  func cycleTarget() {
    guard isOpen else { return }
    if cycle.isEmpty {
      cycle = TargetCycle(current: panel.model.target, candidates: panel.model.cycleTargets)
    }
    guard let next = cycle.next() else { return }
    applyTarget(next)
  }

  private func applyTarget(_ target: PaletteTarget) {
    guard isOpen else { return }
    setupTask?.cancel()
    let root = target.root
    // T23。選び直した対象はこの録音の間だけ持ち越す。
    chosenTarget = target
    panel.model.setPickingFolder(false)
    panel.model.target = target
    panel.model.targetUnresolved = false
    panel.model.resolvingTarget = false
    hud.model.repositoryRoot = root
    onMetric(.targetResolved(target.source.rawValue))
    voxLog("palette_target source=\(target.source.rawValue) root=\(voxLoggable(path: root))")

    // 前の root のファイルと候補は先に捨てる（読み直しの間に古いパスを挿入させない）。
    panel.model.reset()
    setupTask = Task { @MainActor in
      await loadContents(root: root)
    }
  }

  /// T23。履歴に無いフォルダを初めて指定する導線。`NSApp.activate` は呼ばない（前面アプリを
  /// 変えない）。`runModal` は録音中の main の実行を止めるので `begin` で受ける。
  private func chooseFolder() {
    guard folderPanel == nil else { return }
    let open = NSOpenPanel()
    open.canChooseDirectories = true
    open.canChooseFiles = false
    open.allowsMultipleSelection = false
    open.prompt = "選ぶ"
    open.message = "検索対象にするフォルダを選んでください。"
    folderPanel = open
    open.begin { [weak self] response in
      MainActor.assumeIsolated {
        // 片付けた後に届いた応答は捨てる（終わった録音の対象を動かさない）。
        guard let self, self.folderPanel === open else { return }
        self.folderPanel = nil
        guard response == .OK, let folder = open.url?.path else { return }
        self.switchTarget(to: PaletteTarget(root: folder, source: .manual))
      }
    }
  }

  /// esc。フォルダ選択パネル → フォルダ選択モード → パレットの順に閉じる（T23）。
  /// why: 録音中の esc は CGEventTap が飲むのでパネルには届かない。ここで順序を決める。
  func escape() {
    if dismissFolderPanel() { return }
    guard !panel.model.consumeEscape() else { return }
    close(insert: nil, fileNameOnly: false)
  }

  /// 出ていたフォルダ選択パネルを閉じたか。パレットを閉じる・録音を片付けるときも通る。
  @discardableResult
  private func dismissFolderPanel() -> Bool {
    guard let open = folderPanel else { return false }
    folderPanel = nil
    open.cancel(nil)
    return true
  }

  /// 索引と worktree 候補を並行して読む。候補は索引より遅れて届いてよい。
  /// T38-b。登録済みのフォルダでは保持している索引が先に来て、読み直した索引で差し替わる。
  private func loadContents(root: String) async {
    let candidates = Task.detached {
      PaletteTargetResolver.worktreeCandidates(
        root: root,
        deadline: ContinuousClock.now.advanced(
          by: .milliseconds(PaletteTargetResolver.timeoutMilliseconds)))
    }
    await indexes.load(root: root) { [weak self] index in
      guard !Task.isCancelled else { return }
      self?.show(index)
    }
    guard !Task.isCancelled else { return }
    let worktrees = await candidates.value
    guard !Task.isCancelled else { return }
    panel.model.setWorktrees(worktrees)
  }

  private func show(_ index: RepositoryIndex) {
    panel.model.setIndex(
      files: index.files, changedCount: index.changedCount, totalCount: index.totalCount)
    startPreviewUpdates()
  }

  /// 右ペイン。選択が変わったら先頭 40 行を読み直す（ファイル IO なので detached）。
  private func startPreviewUpdates() {
    previewTask?.cancel()
    previewedPath = nil
    previewTask = Task { @MainActor in
      while !Task.isCancelled, isOpen {
        let root = panel.model.target?.root
        let path = panel.model.selectedRow?.file.path
        if path == nil {
          previewedPath = nil
          panel.model.preview = nil
        }
        if let root, let path, path != previewedPath || panel.model.preview == nil {
          previewedPath = path
          let preview = await Task.detached { FileIndexer.preview(root: root, path: path) }.value
          if !Task.isCancelled, panel.model.selectedRow?.file.path == path {
            panel.model.preview = preview
          }
        }
        try? await Task.sleep(for: .milliseconds(60))
      }
    }
  }
}

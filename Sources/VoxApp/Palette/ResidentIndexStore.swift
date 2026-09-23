// T38-b。folders.json のフォルダの索引を常駐で持ち、変更を受けて読み直す。
// 読み直す範囲と捨てる索引の判定は VoxCore.ResidentIndexPolicy。ここは実行と保持だけ。

import Foundation
import VoxCore

/// 常駐索引が外の世界に触る口。検査は git も FSEvents も使わない実装を渡す。
struct ResidentIndexSource {
  var load: @MainActor (String) async -> RepositoryIndex
  var gitDirectory: @MainActor (String) async -> String?
  var snapshot: @MainActor (String) async -> IndexSnapshot?
  var changes: @MainActor (String) async -> [String: FileChangeStatus]?
  /// 監視の開始。始められなければ nil（そのフォルダは常駐させない）。
  var watch:
    @MainActor (_ paths: [String], _ onChange: @escaping @Sendable (FolderChange) -> Void)
      -> FolderWatching?

  // why: git の実行とファイルの列挙は main を止めるので detached に逃がす。
  static let git = ResidentIndexSource(
    load: { root in await Task.detached { FileIndexer.load(root: root) }.value },
    gitDirectory: { root in await Task.detached { FileIndexer.gitDirectory(root: root) }.value },
    snapshot: { root in await Task.detached { FileIndexer.snapshot(root: root) }.value },
    changes: { root in await Task.detached { FileIndexer.changes(root: root) }.value },
    watch: { paths, onChange in FolderWatch(paths: paths, onChange: onChange) })
}

@MainActor
final class ResidentIndexStore {
  /// 常駐索引が持つファイル数の上限。登録 20 件 × 1 件あたりの上限（T38-b）。
  static let defaultFileBudget = FolderHistory.limit * FileIndexer.fallbackFileLimit

  private struct Entry {
    var index: RepositoryIndex
    let resolvedGitDirectory: String
    let watch: FolderWatching
    var rebuildCount = 0
    var isRebuilding = false
    /// 読み直している間に届いた変更。終わってからもう一度読む。
    var queued: IndexRefresh?
    /// 索引を入れ替えた回数。走っている読み込みの結果が古いかを見る。
    var revision = 0
  }

  private let source: ResidentIndexSource
  private let fileBudget: Int
  /// folders.json と同じ新しい順。捨てるのは末尾から。
  private var roots: [String] = []
  private var entries: [String: Entry] = [:]
  private var startTask: Task<Void, Never>?

  init(source: ResidentIndexSource = .git, fileBudget: Int = defaultFileBudget) {
    self.source = source
    self.fileBudget = fileBudget
  }

  /// 起動時に 1 回。folders.json の読み込みと索引づくりで起動を待たせない。
  func start() {
    startTask = Task { @MainActor in
      let history = await Task.detached { FolderHistoryStore.load() }.value
      await register(folders: history.entries.map(\.path))
    }
  }

  func stop() {
    startTask?.cancel()
    startTask = nil
    entries.removeAll()
    roots.removeAll()
  }

  /// git 管理下のフォルダだけを、渡された（新しい）順に常駐させる。
  func register(folders: [String]) async {
    entries.removeAll()
    roots.removeAll()
    for folder in folders.prefix(FolderHistory.limit) {
      guard !Task.isCancelled else { return }
      // why: 上限に届いたところで打ち切る。全件読んでから捨てると、一時的に上限を超えて持つ。
      guard await register(folder: folder) else { break }
    }
    voxLog("index_resident folders=\(roots.count) files=\(residentFileCount)")
  }

  /// まだ常駐させる余地があるか。git 管理外や監視できないフォルダは飛ばして続ける。
  private func register(folder: String) async -> Bool {
    let root = Self.key(folder)
    guard entries[root] == nil, let gitDirectory = await source.gitDirectory(root) else { return true }
    let resolved = Self.resolved(gitDirectory)
    // why: 走査より先に監視を始める（Apple の手順）。後から始めると、走査してから監視が
    // 始まるまでの変更を取りこぼす。FSEvents は実体のパスを返すので、渡す側も実体にする。
    let watch = source.watch([Self.resolved(root), resolved]) { [weak self] change in
      Task { @MainActor in self?.changed(change, root: root) }
    }
    guard let watch else {
      voxLog("index_watch_failed root=\(voxLoggable(path: root))")
      return true
    }
    guard let snapshot = await source.snapshot(root) else { return true }
    roots.append(root)
    entries[root] = Entry(
      index: RepositoryIndex(root: root, snapshot: snapshot), resolvedGitDirectory: resolved,
      watch: watch)
    evictOverBudget()
    return entries[root] != nil
  }

  /// パレットが開いたときの索引。登録済みなら保持している索引を先に渡してから、
  /// 読み直した索引をもう一度渡す。未登録は読み直した 1 度だけ。
  func load(root: String, show: @MainActor (RepositoryIndex) -> Void) async {
    let key = Self.key(root)
    let revision = entries[key]?.revision
    if let resident = entries[key]?.index { show(resident) }
    let index = await source.load(root)
    show(index)
    // why: 読んでいる間に監視の読み直しが新しい索引を入れた回は、古い結果で上書きしない。
    guard let entry = entries[key], entry.revision == revision else { return }
    replace(index, for: key)
  }

  private func replace(_ index: RepositoryIndex, for root: String) {
    entries[root]?.index = index
    entries[root]?.revision += 1
    evictOverBudget()
  }

  private func changed(_ change: FolderChange, root: String) {
    guard let entry = entries[root],
      let refresh = ResidentIndexPolicy.refresh(
        forChangedPaths: change.paths, rescanRequired: change.rescanRequired,
        gitDirectory: entry.resolvedGitDirectory)
    else { return }
    rebuild(root: root, refresh: refresh)
  }

  private func rebuild(root: String, refresh: IndexRefresh) {
    guard var entry = entries[root] else { return }
    guard !entry.isRebuilding else {
      entries[root]?.queued = Self.wider(entry.queued, refresh)
      return
    }
    entry.isRebuilding = true
    entries[root] = entry
    Task { @MainActor in
      let startedAt = voxNowMilliseconds()
      let updated = await reread(root: root, refresh: refresh)
      finish(root: root, updated: updated, refresh: refresh, startedAt: startedAt)
    }
  }

  private func reread(root: String, refresh: IndexRefresh) async -> RepositoryIndex? {
    switch refresh {
    case .changesOnly:
      guard let changes = await source.changes(root), let index = entries[root]?.index else {
        return nil
      }
      return index.replacingChanges(changes)
    case .trackedAndChanges:
      guard let snapshot = await source.snapshot(root) else { return nil }
      return RepositoryIndex(root: root, snapshot: snapshot)
    }
  }

  /// 読み直しの後片付け。診断ログには回数と所要時間だけ出す（パスは `--log-text` のときだけ）。
  private func finish(
    root: String, updated: RepositoryIndex?, refresh: IndexRefresh, startedAt: Double
  ) {
    guard var entry = entries[root] else { return }
    entry.isRebuilding = false
    entry.rebuildCount += 1
    if let updated {
      entry.index = updated
      entry.revision += 1
    }
    let queued = entry.queued
    entry.queued = nil
    entries[root] = entry
    let elapsed = String(format: "%.1f", voxNowMilliseconds() - startedAt)
    voxLog(
      "index_rebuilt scope=\(refresh == .changesOnly ? "changes" : "tracked") "
        + "count=\(entry.rebuildCount) ms=\(elapsed) files=\(entry.index.totalCount) "
        + "root=\(voxLoggable(path: root))")
    evictOverBudget()
    if let queued { rebuild(root: root, refresh: queued) }
  }

  private func evictOverBudget() {
    let sizes = roots.compactMap { root in
      entries[root].map { ResidentIndexSize(root: root, fileCount: $0.index.totalCount) }
    }
    for root in ResidentIndexPolicy.evicted(newestFirst: sizes, budget: fileBudget) {
      entries[root] = nil
      roots.removeAll { $0 == root }
      voxLog("index_evicted root=\(voxLoggable(path: root))")
    }
  }

  private var residentFileCount: Int {
    entries.values.reduce(0) { $0 + $1.index.totalCount }
  }

  private static func wider(_ first: IndexRefresh?, _ second: IndexRefresh) -> IndexRefresh {
    first == .trackedAndChanges || second == .trackedAndChanges ? .trackedAndChanges : .changesOnly
  }

  private static func key(_ root: String) -> String { (root as NSString).standardizingPath }

  private static func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }
}

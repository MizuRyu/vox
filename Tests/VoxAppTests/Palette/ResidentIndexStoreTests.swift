// T38-b 常駐索引の保持。git 管理下だけを登録し、変更の種類で読み直す範囲を変え、
// 上限を超えた索引を捨てる。FSEvents と git は使わない（source を差し替える）。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 常駐索引")
struct ResidentIndexStoreTests {
  /// FSEvents を開かない監視の代わり。常駐索引は生存だけを見る。
  private final class NoWatch: FolderWatching {}

  /// git の代わりに答える置き場。`tracked` にあるフォルダだけ git 管理下として扱う。
  @MainActor
  final class Repositories {
    var tracked: [String: [String]] = [:]
    var changes: [String: [String: FileChangeStatus]] = [:]
    var trackedReads: [String] = []
    var changeReads: [String] = []
    var watched: [[String]] = []
    /// 監視を始められないフォルダ（`FSEventStreamStart` の失敗に相当）。
    var unwatchable: Set<String> = []
    /// 開くたびの読み込みを止めておく。検査が `resumeLoad` で進める。
    var holdsLoad = false
    private var heldLoad: CheckedContinuation<Void, Never>?
    private var handlers: [@Sendable (FolderChange) -> Void] = []

    var source: ResidentIndexSource {
      ResidentIndexSource(
        // 常駐索引と見分けられるように、開くたびの読み込みは別の中身を返す。
        load: { [self] root in
          if holdsLoad { await withCheckedContinuation { heldLoad = $0 } }
          return RepositoryIndex(
            root: root, snapshot: IndexSnapshot(trackedPaths: ["reloaded.swift"], changes: [:]))
        },
        gitDirectory: { [self] root in tracked[root] == nil ? nil : root + "/.git" },
        snapshot: { [self] root in
          trackedReads.append(root)
          guard let paths = tracked[root] else { return nil }
          return IndexSnapshot(trackedPaths: paths, changes: changes[root] ?? [:])
        },
        changes: { [self] root in
          changeReads.append(root)
          return tracked[root] == nil ? nil : changes[root] ?? [:]
        },
        watch: { [self] paths, onChange in
          watched.append(paths)
          guard let root = paths.first, !unwatchable.contains(root) else { return nil }
          handlers.append(onChange)
          return NoWatch()
        })
    }

    var isLoadHeld: Bool { heldLoad != nil }

    func resumeLoad() {
      let held = heldLoad
      heldLoad = nil
      held?.resume()
    }

    func emit(_ paths: [String], rescanRequired: Bool = false) {
      for handler in handlers {
        handler(FolderChange(paths: paths, rescanRequired: rescanRequired))
      }
    }
  }

  private func paths(of index: RepositoryIndex?) -> [String] {
    index?.files.map(\.path) ?? []
  }

  /// 常駐索引を通して読み込み、渡された順に索引を記録する。
  private func shown(_ store: ResidentIndexStore, root: String) async -> [[String]] {
    var shown: [[String]] = []
    await store.load(root: root) { shown.append(paths(of: $0)) }
    return shown
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  @Test("git 管理下のフォルダだけ常駐させ、作業ツリーと git ディレクトリを監視する")
  func onlyGitFoldersBecomeResident() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git", "/plain"])

    #expect(
      await shown(store, root: "/git") == [["a.swift"], ["reloaded.swift"]],
      "登録済みのフォルダで保持している索引を先に出していない")
    #expect(
      await shown(store, root: "/plain") == [["reloaded.swift"]],
      "git 管理外のフォルダを常駐させた")
    #expect(repositories.watched == [["/git", "/git/.git"]], "監視の対象が違う: \(repositories.watched)")
  }

  @Test("作業ツリーの変更は status だけ読み直し、追跡ファイルの一覧を保つ")
  func aWorkingTreeChangeKeepsTheTrackedPaths() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift", "b.swift"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git"])

    repositories.changes["/git"] = ["b.swift": .modified]
    repositories.emit(["/git/b.swift"])
    await waitUntil { repositories.changeReads == ["/git"] }

    #expect(repositories.trackedReads == ["/git"], "ls-files を読み直した: \(repositories.trackedReads)")
    let shown = await shown(store, root: "/git")
    #expect(
      shown.first == ["b.swift", "a.swift"],
      "追跡ファイルを保ったまま変更を反映していない: \(shown)")
  }

  @Test("`.git/index` の変更では追跡ファイルの一覧も読み直す")
  func anIndexChangeRereadsTheTrackedPaths() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git"])

    repositories.tracked["/git"] = ["a.swift", "c.swift"]
    repositories.emit(["/git/.git/index"])
    await waitUntil { repositories.trackedReads.count == 2 }

    #expect(repositories.changeReads.isEmpty, "status だけの読み直しが混ざった: \(repositories.changeReads)")
    let shown = await shown(store, root: "/git")
    #expect(shown.first == ["a.swift", "c.swift"], "追跡ファイルを読み直していない: \(shown)")
  }

  @Test("上限を超えた索引は古い順に捨て、開くたびの読み込みに戻す")
  func indexesOverTheBudgetAreDropped() async {
    let repositories = Repositories()
    repositories.tracked["/new"] = (0..<60).map { "new/\($0).swift" }
    repositories.tracked["/old"] = (0..<60).map { "old/\($0).swift" }
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 100)
    await store.register(folders: ["/new", "/old"])

    #expect(await shown(store, root: "/new").count == 2, "上限内の索引を捨てた")
    #expect(
      await shown(store, root: "/old").count == 1, "上限を超えたのに古い索引が残った")
  }

  @Test("常駐させるのは新しい順に 20 件まで")
  func onlyTheNewestTwentyFoldersBecomeResident() async {
    let repositories = Repositories()
    let folders = (0..<21).map { "/git\($0)" }
    for folder in folders { repositories.tracked[folder] = ["a.swift"] }
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: folders)

    #expect(await shown(store, root: folders[19]).count == 2, "20 件目を常駐させていない")
    #expect(await shown(store, root: folders[20]).count == 1, "21 件目を常駐させた")
  }

  @Test("取りこぼしの申告では、パスに関係なく追跡ファイルも読み直す")
  func aDroppedBatchRereadsTheTrackedPaths() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git"])

    repositories.tracked["/git"] = ["a.swift", "c.swift"]
    repositories.emit(["/git/.git/objects/ab/cdef"], rescanRequired: true)
    await waitUntil { repositories.trackedReads.count == 2 }

    let shown = await shown(store, root: "/git")
    #expect(shown.first == ["a.swift", "c.swift"], "取りこぼしの後に追跡ファイルを読み直していない: \(shown)")
  }

  @Test("監視を始められないフォルダは常駐させない")
  func anUnwatchableFolderIsNotResident() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift"]
    repositories.tracked["/other"] = ["b.swift"]
    repositories.unwatchable = ["/git"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git", "/other"])

    #expect(await shown(store, root: "/git").count == 1, "監視できないフォルダを常駐させた")
    #expect(await shown(store, root: "/other").count == 2, "後続のフォルダまで飛ばした")
  }

  @Test("開くたびの読み込みが遅れても、先に届いた監視の更新を上書きしない")
  func aSlowReloadDoesNotOverwriteANewerRebuild() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git"])

    repositories.holdsLoad = true
    var shownDuringLoad: [[String]] = []
    let opening = Task { @MainActor in
      await store.load(root: "/git") { shownDuringLoad.append(paths(of: $0)) }
    }
    await waitUntil { repositories.isLoadHeld }

    // 読み込みを待たせている間に .git/index が動く（新しい索引が入る）。
    repositories.tracked["/git"] = ["a.swift", "c.swift"]
    repositories.emit(["/git/.git/index"])
    await waitUntil { repositories.trackedReads.count == 2 }
    repositories.holdsLoad = false
    repositories.resumeLoad()
    await opening.value

    #expect(
      shownDuringLoad == [["a.swift"], ["reloaded.swift"]],
      "開いた側には読み込んだ索引を出す: \(shownDuringLoad)")
    let shown = await shown(store, root: "/git")
    #expect(
      shown.first == ["a.swift", "c.swift"],
      "古い読み込みが新しい索引を上書きした: \(shown)")
  }

  @Test("末尾の `/` が付いたパスでも同じ索引を返す")
  func aTrailingSlashFindsTheSameIndex() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git/"])

    #expect(await shown(store, root: "/git").count == 2, "同じフォルダを別のキーで持っている")
  }
}

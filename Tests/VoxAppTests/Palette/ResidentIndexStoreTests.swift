// T38-b 常駐索引の保持。git 管理下だけを登録し、変更の種類で読み直す範囲を変え、
// 上限を超えた索引を捨てる。FSEvents と git は使わない（source を差し替える）。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 常駐索引")
struct ResidentIndexStoreTests {
  /// git の代わりに答える置き場。`tracked` にあるフォルダだけ git 管理下として扱う。
  @MainActor
  final class Repositories {
    var tracked: [String: [String]] = [:]
    var changes: [String: [String: FileChangeStatus]] = [:]
    var trackedReads: [String] = []
    var changeReads: [String] = []
    var watched: [[String]] = []
    /// 監視を始めた口。検査から変更を流し込む。
    private var handlers: [@Sendable ([String]) -> Void] = []

    var source: ResidentIndexSource {
      ResidentIndexSource(
        // 常駐索引と見分けられるように、開くたびの読み込みは別の中身を返す。
        load: { root in
          RepositoryIndex(
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
          handlers.append(onChange)
          return nil
        })
    }

    func emit(_ paths: [String]) {
      for handler in handlers { handler(paths) }
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

  @Test("末尾の `/` が付いたパスでも同じ索引を返す")
  func aTrailingSlashFindsTheSameIndex() async {
    let repositories = Repositories()
    repositories.tracked["/git"] = ["a.swift"]
    let store = ResidentIndexStore(source: repositories.source, fileBudget: 1000)
    await store.register(folders: ["/git/"])

    #expect(await shown(store, root: "/git").count == 2, "同じフォルダを別のキーで持っている")
  }
}

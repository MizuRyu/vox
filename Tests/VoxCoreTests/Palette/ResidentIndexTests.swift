// T38-b 常駐索引の判定。FSEvents が伝えたパスから読み直す範囲、status だけ読み直した更新の合成、
// メモリ上限を超えたときに捨てる索引。FSEvents の実監視は検査しない（VoxApp 側）。

import Foundation
import Testing
import VoxCore

@Suite("Palette: 常駐索引の判定")
struct ResidentIndexTests {
  private let gitDirectory = "/repos/vox/.git"

  private func refresh(
    _ paths: [String], rescanRequired: Bool = false, gitDirectory: String? = nil
  ) -> IndexRefresh? {
    ResidentIndexPolicy.refresh(
      forChangedPaths: paths, rescanRequired: rescanRequired,
      gitDirectory: gitDirectory ?? self.gitDirectory)
  }

  // MARK: 読み直す範囲

  @Test("作業ツリーのファイルは status だけ読み直す")
  func aWorkingTreeChangeRereadsOnlyTheStatus() {
    #expect(refresh(["/repos/vox/Sources/App.swift", "/repos/vox/README.md"]) == .changesOnly)
  }

  @Test("`.git/index` と `.git/HEAD` は追跡ファイルの一覧も読み直す")
  func theIndexAndHeadRereadTheTrackedPaths() {
    for path in ["/repos/vox/.git/index", "/repos/vox/.git/HEAD"] {
      #expect(refresh([path]) == .trackedAndChanges, "\(path) で追跡ファイルを読み直していない")
    }
  }

  @Test("`.git` の中の index・HEAD 以外は読み直さない")
  func otherPathsInsideTheGitDirectoryAreIgnored() {
    let paths = [
      "/repos/vox/.git/index.lock", "/repos/vox/.git/HEAD.lock",
      "/repos/vox/.git/refs/heads/main", "/repos/vox/.git/objects/ab/cdef", "/repos/vox/.git"
    ]
    for path in paths {
      #expect(refresh([path]) == nil, "\(path) で読み直しが走る")
    }
  }

  @Test("別の場所にある worktree でも git ディレクトリの index を見分ける")
  func aLinkedWorktreeFindsItsOwnIndex() {
    let linked = "/repos/vox/.git/worktrees/feature"
    #expect(
      refresh(["\(linked)/index"], gitDirectory: linked) == .trackedAndChanges,
      "worktree の index を見分けていない")
    #expect(
      refresh(["/work/feature/Sources/App.swift"], gitDirectory: linked) == .changesOnly,
      "作業ツリーの変更が status の読み直しにならない")
  }

  @Test("変更が無ければ読み直さない")
  func noPathsMeanNoWork() {
    #expect(refresh([]) == nil)
  }

  @Test("作業ツリーと index が同じ束で届いたら追跡ファイルも読み直す")
  func aBatchWithTheIndexRereadsTheTrackedPaths() {
    #expect(
      refresh(["/repos/vox/Sources/App.swift", "/repos/vox/.git/index"]) == .trackedAndChanges)
  }

  @Test("取りこぼしを申告された回は、パスを見ずに全部読み直す")
  func aDroppedBatchRereadsEverything() {
    #expect(
      refresh(["/repos/vox/.git/objects/ab/cdef"], rescanRequired: true) == .trackedAndChanges,
      "無視するパスで読み直しを省いた")
    #expect(
      refresh([], rescanRequired: true) == .trackedAndChanges, "パスが無い申告で読み直しを省いた")
  }

  @Test("末尾の `/` が付いた git ディレクトリでも index を見分ける")
  func aTrailingSlashDoesNotHideTheIndex() {
    #expect(
      refresh(["/repos/vox/.git/index"], gitDirectory: "/repos/vox/.git/") == .trackedAndChanges)
  }

  // MARK: status だけ読み直した更新

  private var snapshot: IndexSnapshot {
    IndexSnapshot(
      trackedPaths: ["Sources/App.swift", "README.md"], changes: ["README.md": .modified])
  }

  @Test("status だけ読み直しても追跡ファイルの一覧は保つ")
  func rereadingTheStatusKeepsTheTrackedPaths() {
    let updated = snapshot.replacingChanges(["Sources/App.swift": .added])
    #expect(
      updated.trackedPaths == ["Sources/App.swift", "README.md"],
      "追跡ファイルが変わった: \(updated.trackedPaths)")
    #expect(updated.changes == ["Sources/App.swift": .added], "変更状態が入れ替わっていない")
    #expect(
      updated.files.first == IndexedFile(path: "Sources/App.swift", status: .added),
      "変更ファイルが先頭に来ていない: \(updated.files)")
    #expect(updated.files.count == 2, "追跡ファイルが二重に数えられた: \(updated.files)")
  }

  @Test("変更が空になった更新でも追跡ファイルは残る")
  func clearingTheChangesKeepsTheTrackedPaths() {
    let updated = snapshot.replacingChanges([:])
    #expect(updated.changes.isEmpty, "変更状態が残った: \(updated.changes)")
    #expect(
      updated.files.map(\.path) == ["Sources/App.swift", "README.md"],
      "追跡ファイルの並びが変わった: \(updated.files.map(\.path))")
    #expect(updated.files.allSatisfy { !$0.isChanged }, "変更バッジが残った: \(updated.files)")
  }

  // MARK: メモリ上限

  private func sizes(_ counts: [(String, Int)]) -> [ResidentIndexSize] {
    counts.map { ResidentIndexSize(root: $0.0, fileCount: $0.1) }
  }

  @Test("上限に収まっていれば何も捨てない")
  func nothingIsDroppedUnderTheBudget() {
    let evicted = ResidentIndexPolicy.evicted(
      newestFirst: sizes([("/a", 100), ("/b", 150)]), budget: 250)
    #expect(evicted.isEmpty, "上限ちょうどで捨てた: \(evicted)")
  }

  @Test("上限を超えた分は古い順に捨てる")
  func theOldestIndexesAreDroppedFirst() {
    #expect(
      ResidentIndexPolicy.evicted(
        newestFirst: sizes([("/a", 100), ("/b", 100), ("/c", 100)]), budget: 250) == ["/c"])
  }

  @Test("入り切らないフォルダより古いものはまとめて捨てる")
  func everythingOlderThanTheOverflowIsDropped() {
    #expect(
      ResidentIndexPolicy.evicted(
        newestFirst: sizes([("/a", 300), ("/b", 10), ("/c", 10)]), budget: 250)
        == ["/a", "/b", "/c"], "並びを飛ばして採っている")
  }

  @Test("空の一覧は何も捨てない")
  func anEmptyListDropsNothing() {
    #expect(ResidentIndexPolicy.evicted(newestFirst: [], budget: 250).isEmpty)
  }
}

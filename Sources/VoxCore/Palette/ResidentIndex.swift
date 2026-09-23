// T38-b。登録フォルダの常駐索引。どこまで読み直すか、何を保つか、どれを捨てるかだけを決める。
// FSEvents の監視と git の実行は VoxApp（ResidentIndexStore / FolderWatch）。

import Foundation

/// 変更を受けて読み直す範囲。
public enum IndexRefresh: Equatable, Sendable {
  /// `git status --porcelain -z` だけ。追跡ファイルの一覧は保つ。
  case changesOnly
  /// `git ls-files -z` も読み直す。
  case trackedAndChanges
}

/// 1 リポジトリ分の索引の素。追跡ファイルと変更状態を別々に持つので、
/// status だけ読み直した更新で追跡ファイルの一覧を保てる。
public struct IndexSnapshot: Equatable, Sendable {
  public let trackedPaths: [String]
  public let changes: [String: FileChangeStatus]

  public init(trackedPaths: [String], changes: [String: FileChangeStatus]) {
    self.trackedPaths = trackedPaths
    self.changes = changes
  }

  /// 一覧に出す並び（変更ファイルが先頭）。
  public var files: [IndexedFile] {
    FileIndex.build(trackedPaths: trackedPaths, changes: changes)
  }

  public func replacingChanges(_ changes: [String: FileChangeStatus]) -> IndexSnapshot {
    IndexSnapshot(trackedPaths: trackedPaths, changes: changes)
  }
}

/// 常駐させている 1 フォルダ分の大きさ。捨てる順を決めるのに使う。
public struct ResidentIndexSize: Equatable, Sendable {
  public let root: String
  public let fileCount: Int

  public init(root: String, fileCount: Int) {
    self.root = root
    self.fileCount = fileCount
  }
}

public enum ResidentIndexPolicy {
  /// FSEvents が伝えたパスから読み直す範囲を決める。`nil` は読み直さない。
  /// git ディレクトリの中は `index` と `HEAD` だけ見る（`index.lock` や `refs/` は無視する）。
  /// why: `rescanRequired`（取りこぼしや集約の申告）の回はパスが当てにならないので、全部読み直す。
  public static func refresh(
    forChangedPaths paths: [String], rescanRequired: Bool, gitDirectory: String
  ) -> IndexRefresh? {
    guard !rescanRequired else { return .trackedAndChanges }
    let gitDirectory = FilePathFormat.standardized(gitDirectory)
    var refresh: IndexRefresh?
    for path in paths {
      let path = FilePathFormat.standardized(path)
      // why: git ディレクトリそのものの更新時刻からは、何を読み直すべきか決まらない。
      guard path != gitDirectory else { continue }
      guard let inGitDirectory = FilePathFormat.relative(path: path, root: gitDirectory) else {
        refresh = .changesOnly
        continue
      }
      if inGitDirectory == "index" || inGitDirectory == "HEAD" { return .trackedAndChanges }
    }
    return refresh
  }

  /// 上限を超えた索引。新しい順に受け取り、入り切らなかったフォルダとそれより古いものを返す。
  /// why: 入り切らない 1 件だけ飛ばして古い方を残すと、捨てる順が「古い順」でなくなる。
  public static func evicted(newestFirst sizes: [ResidentIndexSize], budget: Int) -> [String] {
    var total = 0
    for (offset, size) in sizes.enumerated() {
      total += size.fileCount
      guard total <= budget else { return sizes[offset...].map(\.root) }
    }
    return []
  }
}

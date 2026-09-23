// パレットのファイル索引とプレビュー。git の出力を取ってくるだけで、
// 並びと検索は VoxCore.FileIndex / FuzzyMatch が持つ（テストのため）。
//
// git 管理外のディレクトリでは `fd -t f` にフォールバックする（指示書）。
// M3 は「開いたときに 1 回読む」。FSEvents の差分更新（設計書 §5）は入れていない。

import Foundation
import VoxCore

struct RepositoryIndex: Sendable {
  let root: String
  // why: 追跡ファイルと変更状態を別々に持つと、status だけ読み直した更新で並びを組み直せる（T38-b）。
  let snapshot: IndexSnapshot
  let files: [IndexedFile]
  /// ヘッダの「Changes  n / total」用。
  var changedCount: Int { snapshot.changes.count }
  var totalCount: Int { files.count }

  static let empty = RepositoryIndex(root: "", snapshot: .empty)

  init(root: String, snapshot: IndexSnapshot) {
    self.root = root
    self.snapshot = snapshot
    files = snapshot.files
  }

  // why: 追跡ファイルの一覧は `git status` の読み直しでは変わらない（T38-b）。
  func replacingChanges(_ changes: [String: FileChangeStatus]) -> RepositoryIndex {
    RepositoryIndex(root: root, snapshot: snapshot.replacingChanges(changes))
  }
}

struct FilePreview: Sendable {
  let title: String
  let detail: String
  /// 表示する行。バイナリや読めないファイルでは空。
  let lines: [String]
  let notice: String?
}

enum FileIndexer {
  static let previewLineCount = 40
  /// git 管理外のフォールバックで拾う上限。
  static let fallbackFileLimit = 20_000

  /// プロセスを起動するので detached で走らせる。
  nonisolated static func load(root: String) -> RepositoryIndex {
    guard let snapshot = snapshot(root: root) else { return fallbackIndex(root: root) }
    return RepositoryIndex(root: root, snapshot: snapshot)
  }

  /// git 管理下の追跡ファイルと変更状態。管理外なら nil。
  nonisolated static func snapshot(root: String) -> IndexSnapshot? {
    guard let tracked = Shell.run("git", ["-C", root, "ls-files", "-z"]), tracked.succeeded else {
      return nil
    }
    return IndexSnapshot(
      trackedPaths: GitOutputParser.trackedPaths(fromNulSeparated: tracked.standardOutput),
      changes: changes(root: root) ?? [:])
  }

  /// T38-b。変更状態だけ読み直す。
  nonisolated static func changes(root: String) -> [String: FileChangeStatus]? {
    guard let status = Shell.run("git", ["-C", root, "status", "--porcelain", "-z"]),
      status.succeeded
    else { return nil }
    return GitOutputParser.changes(fromNulSeparated: status.standardOutput)
  }

  /// T38-b。監視するリポジトリの実体。linked worktree では作業ツリーの外を指す。
  nonisolated static func gitDirectory(root: String) -> String? {
    guard let output = Shell.run("git", ["-C", root, "rev-parse", "--absolute-git-dir"]),
      output.succeeded
    else { return nil }
    let path = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  /// `.gitignore` を見てくれる点で fd が望ましいが、無ければ FileManager で拾う。
  private nonisolated static func fallbackIndex(root: String) -> RepositoryIndex {
    var paths: [String] = []
    if let output = Shell.run("fd", ["-t", "f", "--strip-cwd-prefix"], currentDirectory: root),
      output.succeeded {
      paths = output.standardOutput.split(separator: "\n").map(String.init)
    } else {
      paths = enumeratePaths(root: root)
    }
    return RepositoryIndex(
      root: root,
      snapshot: IndexSnapshot(trackedPaths: Array(paths.prefix(fallbackFileLimit)), changes: [:]))
  }

  private nonisolated static func enumeratePaths(root: String) -> [String] {
    // 列挙が返す URL は実体のパスなので、root も実体にしてから相対化する。
    let url = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var paths: [String] = []
    for case let fileURL as URL in enumerator {
      guard paths.count < fallbackFileLimit else { break }
      guard
        (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
        let path = FilePathFormat.relative(path: fileURL.path, root: url.path)
      else { continue }
      paths.append(path)
    }
    return paths.sorted()
  }

  /// 右ペイン。先頭 40 行。バイナリは「プレビューなし」。
  nonisolated static func preview(root: String, path: String) -> FilePreview {
    let name = PaletteInsertion.fileName(of: path)
    let result = BoundedFileReader.read(
      root: root, relativePath: path, byteLimit: 64 * 1024, lineLimit: previewLineCount)
    let detail = result.fileSize.map { formatSize(Int(clamping: $0)) } ?? "—"
    switch result.status {
    case .text:
      return FilePreview(title: name, detail: detail, lines: result.lines, notice: nil)
    case .binary:
      return FilePreview(title: name, detail: detail, lines: [], notice: "プレビューなし（バイナリ）")
    case .invalidEncoding:
      return FilePreview(title: name, detail: detail, lines: [], notice: "プレビューなし（読めない文字コード）")
    case .outsideRoot, .notRegularFile, .unavailable:
      return FilePreview(title: name, detail: detail, lines: [], notice: "プレビューなし")
    }
  }

  private nonisolated static func formatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kilobytes = Double(bytes) / 1024
    if kilobytes < 1024 { return String(format: "%.1f KB", kilobytes) }
    return String(format: "%.1f MB", kilobytes / 1024)
  }
}

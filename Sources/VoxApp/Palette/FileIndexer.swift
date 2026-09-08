// パレットのファイル索引とプレビュー。git の出力を取ってくるだけで、
// 並びと検索は VoxCore.FileIndex / FuzzyMatch が持つ（テストのため）。
//
// git 管理外のディレクトリでは `fd -t f` にフォールバックする（指示書）。
// M3 は「開いたときに 1 回読む」。FSEvents の差分更新（設計書 §5）は入れていない。

import Foundation
import VoxCore

struct RepositoryIndex: Sendable {
  let root: String
  let files: [IndexedFile]
  /// ヘッダの「Changes  n / total」用。
  let changedCount: Int
  let totalCount: Int

  static let empty = RepositoryIndex(root: "", files: [], changedCount: 0, totalCount: 0)
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
    if let index = gitIndex(root: root) { return index }
    return fallbackIndex(root: root)
  }

  private nonisolated static func gitIndex(root: String) -> RepositoryIndex? {
    guard let tracked = Shell.run("git", ["-C", root, "ls-files", "-z"]), tracked.succeeded else {
      return nil
    }
    let paths = GitOutputParser.trackedPaths(fromNulSeparated: tracked.standardOutput)
    var changes: [String: FileChangeStatus] = [:]
    if let status = Shell.run("git", ["-C", root, "status", "--porcelain", "-z"]), status.succeeded {
      changes = GitOutputParser.changes(fromNulSeparated: status.standardOutput)
    }
    let files = FileIndex.build(trackedPaths: paths, changes: changes)
    return RepositoryIndex(
      root: root, files: files, changedCount: changes.count, totalCount: files.count)
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
    let files = FileIndex.build(trackedPaths: Array(paths.prefix(fallbackFileLimit)), changes: [:])
    return RepositoryIndex(root: root, files: files, changedCount: 0, totalCount: files.count)
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

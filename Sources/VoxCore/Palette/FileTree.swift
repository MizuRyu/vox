import Foundation

public enum FileTreeItemKind: Sendable, Equatable {
  case directory
  case file
}

/// A flattened row from a repository file tree. Directory paths never represent
/// insertable files; callers must use `file` when committing or previewing.
public struct FileTreeRow: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: FileTreeItemKind
  public let path: String
  public let name: String
  public let depth: Int
  public let file: IndexedFile?
  public let isExpanded: Bool

  public init(
    kind: FileTreeItemKind, path: String, name: String, depth: Int,
    file: IndexedFile? = nil, isExpanded: Bool = false
  ) {
    self.id = (kind == .directory ? "d:" : "f:") + path
    self.kind = kind
    self.path = path
    self.name = name
    self.depth = depth
    self.file = file
    self.isExpanded = isExpanded
  }
}

/// A deterministic hierarchy built solely from the paths already present in the
/// repository index. It performs no filesystem access.
public struct FileTree: Sendable {
  private struct Node: Sendable {
    let name: String
    let path: String
    let directories: [Node]
    let files: [IndexedFile]
  }

  private let roots: [Node]
  private let rootFiles: [IndexedFile]

  public init(files: [IndexedFile]) {
    let builder = Builder()
    for file in files where Self.isSafeRelativePath(file.path) {
      builder.insert(file)
    }
    roots = builder.sortedDirectories()
    rootFiles = builder.sortedFiles()
  }

  /// Empty queries respect explicit expansion. Search results show all ancestors
  /// of matching files regardless of the saved expansion state.
  public func rows(
    query: String, expandedDirectories: Set<String>, matchLimit: Int = 200
  ) -> [FileTreeRow] {
    if query.isEmpty {
      var result: [FileTreeRow] = []
      append(roots, rootFiles, depth: 0, expanded: expandedDirectories, to: &result)
      return result
    }

    let matches = FileIndex.rows(query: query, in: allFiles(), limit: matchLimit)
    let includedFiles = Set(matches.map(\.file.path))
    var includedDirectories = Set<String>()
    for path in includedFiles {
      let parts = path.split(separator: "/").dropLast()
      var current = ""
      for part in parts {
        current = current.isEmpty ? String(part) : current + "/" + part
        includedDirectories.insert(current)
      }
    }
    var result: [FileTreeRow] = []
    appendFiltered(
      roots, rootFiles, depth: 0, directories: includedDirectories,
      files: includedFiles, to: &result)
    return result
  }

  public static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else { return false }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  private func allFiles() -> [IndexedFile] {
    var result = rootFiles
    func collect(_ nodes: [Node]) {
      for node in nodes {
        result.append(contentsOf: node.files)
        collect(node.directories)
      }
    }
    collect(roots)
    return result
  }

  private func append(
    _ directories: [Node], _ files: [IndexedFile], depth: Int,
    expanded: Set<String>, to result: inout [FileTreeRow]
  ) {
    for directory in directories {
      let open = expanded.contains(directory.path)
      result.append(
        FileTreeRow(
          kind: .directory, path: directory.path, name: directory.name,
          depth: depth, isExpanded: open))
      if open {
        append(
          directory.directories, directory.files, depth: depth + 1, expanded: expanded, to: &result)
      }
    }
    for file in files {
      result.append(
        FileTreeRow(
          kind: .file, path: file.path,
          name: file.path.split(separator: "/").last.map(String.init) ?? file.path,
          depth: depth, file: file))
    }
  }

  private func appendFiltered(
    _ directories: [Node], _ files: [IndexedFile], depth: Int,
    directories includedDirectories: Set<String>, files includedFiles: Set<String>,
    to result: inout [FileTreeRow]
  ) {
    for directory in directories where includedDirectories.contains(directory.path) {
      result.append(
        FileTreeRow(
          kind: .directory, path: directory.path, name: directory.name,
          depth: depth, isExpanded: true))
      appendFiltered(
        directory.directories, directory.files, depth: depth + 1,
        directories: includedDirectories, files: includedFiles, to: &result)
    }
    for file in files where includedFiles.contains(file.path) {
      result.append(
        FileTreeRow(
          kind: .file, path: file.path,
          name: file.path.split(separator: "/").last.map(String.init) ?? file.path,
          depth: depth, file: file))
    }
  }

  private final class Builder {
    var directories: [String: Builder] = [:]
    var files: [IndexedFile] = []
    var name = ""
    var path = ""

    func insert(_ file: IndexedFile) {
      let parts = file.path.split(separator: "/").map(String.init)
      guard let fileName = parts.last else { return }
      var cursor = self
      var current = ""
      for part in parts.dropLast() {
        current = current.isEmpty ? part : current + "/" + part
        if cursor.directories[part] == nil {
          let child = Builder()
          child.name = part
          child.path = current
          cursor.directories[part] = child
        }
        cursor = cursor.directories[part]!
      }
      if !fileName.isEmpty { cursor.files.append(file) }
    }

    func sortedDirectories() -> [Node] {
      directories.values.sorted { $0.name < $1.name }.map {
        Node(
          name: $0.name, path: $0.path, directories: $0.sortedDirectories(), files: $0.sortedFiles()
        )
      }
    }

    func sortedFiles() -> [IndexedFile] {
      files.sorted { left, right in
        let leftName = left.path.split(separator: "/").last.map(String.init) ?? left.path
        let rightName = right.path.split(separator: "/").last.map(String.init) ?? right.path
        if leftName != rightName { return leftName < rightName }
        return left.path < right.path
      }
    }
  }
}

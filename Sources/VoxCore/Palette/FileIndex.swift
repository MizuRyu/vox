// パレットのファイル索引。`git ls-files` と `git status --porcelain` の出力を受け取り、
// 並びと検索だけをここで決める（プロセス実行は Vox 側の FileIndexer）。
//
// クエリが空のときは変更ファイルを上に出す（設計書 §5、ADR-005）。
// git の出力は `-z` 前提。NUL 区切りにするとパスの quoting が起きないため。

import Foundation

public enum FileChangeStatus: String, Sendable, Equatable {
  case modified = "M"
  case added = "A"
  case deleted = "D"
  case untracked = "??"
}

public struct IndexedFile: Equatable, Sendable {
  public let path: String
  public let status: FileChangeStatus?

  public init(path: String, status: FileChangeStatus? = nil) {
    self.path = path
    self.status = status
  }

  public var isChanged: Bool { status != nil }
}

/// 一覧に出す 1 行。`matchedIndices` はハイライト用（クエリが空なら空配列）。
public struct PaletteRow: Equatable, Sendable {
  public let file: IndexedFile
  public let matchedIndices: [Int]

  public init(file: IndexedFile, matchedIndices: [Int] = []) {
    self.file = file
    self.matchedIndices = matchedIndices
  }
}

public enum GitOutputParser {
  /// `git ls-files -z` の出力。
  public static func trackedPaths(fromNulSeparated output: String) -> [String] {
    output.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
  }

  /// `git status --porcelain -z` の出力。レコードは `XY<space>path`。
  /// `R` / `C` は「新しいパス」のレコードの直後に「元のパス」のレコードが続くので読み飛ばす。
  public static func changes(fromNulSeparated output: String) -> [String: FileChangeStatus] {
    var result: [String: FileChangeStatus] = [:]
    let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    var index = 0
    while index < records.count {
      let record = records[index]
      index += 1
      guard record.count > 3 else { continue }
      let code = String(record.prefix(2))
      let path = String(record.dropFirst(3))
      guard !path.isEmpty else { continue }
      if code.hasPrefix("R") || code.hasPrefix("C") {
        // 直後の元パスのレコードを食べる。
        index += 1
      }
      if let status = status(forCode: code) {
        result[path] = status
      }
    }
    return result
  }

  /// XY の 2 文字から表示するバッジを決める。index 側 (X) を優先し、無ければ worktree 側 (Y)。
  static func status(forCode code: String) -> FileChangeStatus? {
    if code == "??" { return .untracked }
    let characters = Array(code)
    guard characters.count == 2 else { return nil }
    for character in characters where character != " " {
      switch character {
      case "D": return .deleted
      case "A": return .added
      case "M", "R", "C", "U", "T": return .modified
      default: continue
      }
    }
    return nil
  }
}

public enum FileIndex {
  /// 索引を組む。**変更ファイルが先頭**、続いて追跡ファイル（git の並びのまま）。
  public static func build(trackedPaths: [String], changes: [String: FileChangeStatus])
    -> [IndexedFile] {
    let changedPaths = changes.keys.sorted()
    var seen = Set(changedPaths)
    var files = changedPaths.map { IndexedFile(path: $0, status: changes[$0]) }
    for path in trackedPaths where !seen.contains(path) {
      seen.insert(path)
      files.append(IndexedFile(path: path))
    }
    return files
  }

  /// 一覧に出す行を返す。クエリが空なら並び（変更ファイルが上）をそのまま先頭から。
  /// クエリがあれば fuzzy の点順。同点は変更ファイル優先、次にパスの辞書順。
  public static func rows(query: String, in files: [IndexedFile], limit: Int = 200) -> [PaletteRow] {
    guard !query.isEmpty else {
      return files.prefix(limit).map { PaletteRow(file: $0) }
    }
    var scored: [(row: PaletteRow, score: Int)] = []
    for file in files {
      guard let match = FuzzyMatch.match(query: query, path: file.path) else { continue }
      scored.append(
        (PaletteRow(file: file, matchedIndices: match.matchedIndices), match.score))
    }
    scored.sort { left, right in
      if left.score != right.score { return left.score > right.score }
      if left.row.file.isChanged != right.row.file.isChanged { return left.row.file.isChanged }
      return left.row.file.path < right.row.file.path
    }
    return scored.prefix(limit).map(\.row)
  }
}

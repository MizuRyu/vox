// M3 fuzzy 検索、git 出力の解釈、索引の並び、Orca アダプタ。

import Foundation
import Testing
import VoxCore

@Suite("Palette: 索引と検索")
struct FileIndexTests {
  // MARK: M3 fuzzy 検索（外部ライブラリなし。連続一致とファイル名一致に加点する）

  @Test("Fuzzy match is nil when the query is not A subsequence")
  func fuzzyMatchIsNilWhenTheQueryIsNotASubsequence() throws {
    #expect(FuzzyMatch.match(query: "zzz", path: "Sources/Vox/HudPanel.swift") == nil, "subsequence でないクエリが一致した")
  }

  @Test("Fuzzy match is case insensitive")
  func fuzzyMatchIsCaseInsensitive() throws {
    let lower = try #require(FuzzyMatch.match(query: "hud", path: "Sources/Vox/HudPanel.swift"))
    let upper = try #require(FuzzyMatch.match(query: "HUD", path: "Sources/Vox/HudPanel.swift"))
    #expect(lower == upper, "大文字小文字で結果が変わる")
  }

  @Test("Fuzzy prefers A match inside the file name")
  func fuzzyPrefersAMatchInsideTheFileName() throws {
    try expectRanksHigher(
      query: "core", better: "Sources/Vox/Core.swift", worse: "Sources/VoxCore/FileIndex.swift")
  }

  @Test("Fuzzy prefers consecutive hits over scattered ones")
  func fuzzyPrefersConsecutiveHitsOverScatteredOnes() throws {
    try expectRanksHigher(query: "ring", better: "audio/ring.swift", worse: "a/r_i_n_g.swift")
  }

  @Test("Fuzzy prefers the shorter path on equal hits")
  func fuzzyPrefersTheShorterPathOnEqualHits() throws {
    try expectRanksHigher(query: "hud", better: "a/hud.swift", worse: "a/b/c/d/e/f/hud.swift")
  }

  @Test("Fuzzy reports the matched indices for highlighting")
  func fuzzyReportsTheMatchedIndicesForHighlighting() throws {
    let match = try #require(
      FuzzyMatch.match(query: "buf", path: "audio/buffer.swift"), "一致しなかった")
    #expect(match.matchedIndices == [6, 7, 8], "一致位置が違う: \(match.matchedIndices)")
  }

  // MARK: M3 git 出力の解釈（-z 前提。パスの quoting が起きない）

  @Test("Tracked paths are split on nul")
  func trackedPathsAreSplitOnNul() throws {
    let paths = GitOutputParser.trackedPaths(
      fromNulSeparated: "Sources/Vox/App.swift\u{0}docs/design.md\u{0}")
    #expect(paths == ["Sources/Vox/App.swift", "docs/design.md"], "ls-files の解釈が違う: \(paths)")
  }

  @Test("Status porcelain maps each code to A badge")
  func statusPorcelainMapsEachCodeToABadge() throws {
    let changes = GitOutputParser.changes(
      fromNulSeparated: " M a.swift\u{0}A  b.swift\u{0} D c.swift\u{0}?? d.swift\u{0}")
    #expect(
      changes["a.swift"] == .modified
        && changes["b.swift"] == .added
        && changes["c.swift"] == .deleted
        && changes["d.swift"] == .untracked,
      "status のバッジが違う: \(changes)")
  }

  @Test("Status porcelain skips the source path of A rename")
  func statusPorcelainSkipsTheSourcePathOfARename() throws {
    let changes = GitOutputParser.changes(
      fromNulSeparated: "R  new.swift\u{0}old.swift\u{0} M other.swift\u{0}")
    #expect(
      changes["new.swift"] == .modified
        && changes["old.swift"] == nil
        && changes["other.swift"] == .modified
        && changes.count == 2,
      "rename の元パスを食べていない: \(changes)")
  }

  @Test("Status porcelain ignores unknown codes")
  func statusPorcelainIgnoresUnknownCodes() throws {
    let changes = GitOutputParser.changes(fromNulSeparated: "!! ignored.swift\u{0}")
    #expect(changes.isEmpty, "未知のコードを拾った: \(changes)")
  }

  // MARK: M3 索引の並びと検索

  @Test("Empty query puts changed files on top")
  func emptyQueryPutsChangedFilesOnTop() throws {
    let files = FileIndex.build(
      trackedPaths: ["a.swift", "b.swift", "z.swift"], changes: ["z.swift": .modified])
    let rows = FileIndex.rows(query: "", in: files)
    #expect((rows.first?.file.path == "z.swift") && (rows.first?.file.status == .modified), "変更ファイルが先頭に来ていない: \(rows.map(\.file.path))")
  }

  @Test("Empty query keeps tracked order after the changed ones")
  func emptyQueryKeepsTrackedOrderAfterTheChangedOnes() throws {
    let files = FileIndex.build(
      trackedPaths: ["a.swift", "b.swift", "z.swift"], changes: ["z.swift": .modified])
    #expect(files.map(\.path) == ["z.swift", "a.swift", "b.swift"], "追跡ファイルの並びが崩れた: \(files.map(\.path))")
  }

  @Test("Untracked files enter the index even if not tracked")
  func untrackedFilesEnterTheIndexEvenIfNotTracked() throws {
    let files = FileIndex.build(trackedPaths: ["a.swift"], changes: ["new.swift": .untracked])
    #expect(files.map(\.path) == ["new.swift", "a.swift"], "未追跡ファイルが索引に入っていない: \(files.map(\.path))")
  }

  @Test("Query filters out non matching paths")
  func queryFiltersOutNonMatchingPaths() throws {
    let files = FileIndex.build(trackedPaths: ["a.swift", "hud.swift"], changes: [:])
    let rows = FileIndex.rows(query: "hud", in: files)
    #expect(rows.map(\.file.path) == ["hud.swift"], "一致しないパスが残った: \(rows.map(\.file.path))")
  }

  @Test("Query ranks the file name match first")
  func queryRanksTheFileNameMatchFirst() throws {
    let files = FileIndex.build(
      trackedPaths: ["ringbuffer/notes.md", "audio/RingBuffer.swift"], changes: [:])
    let rows = FileIndex.rows(query: "ringbuf", in: files)
    #expect(rows.first?.file.path == "audio/RingBuffer.swift", "ファイル名一致が先頭に来ていない: \(rows.map(\.file.path))")
  }

  @Test("Query tie breaks toward the changed file")
  func queryTieBreaksTowardTheChangedFile() throws {
    // 同じ形のパスなので点は同じ。バッジのあるほうが上に来る。
    let files = FileIndex.build(
      trackedPaths: ["x/hud.swift", "y/hud.swift"], changes: ["y/hud.swift": .modified])
    let rows = FileIndex.rows(query: "hud", in: files)
    #expect(rows.first?.file.path == "y/hud.swift", "同点で変更ファイルが優先されない: \(rows.map(\.file.path))")
  }

  // MARK: Folder tree

  @Test("File tree sorts directories before files by name")
  func fileTreeSortsDirectoriesBeforeFilesByName() throws {
    let tree = FileTree(files: [
      IndexedFile(path: "z.txt"), IndexedFile(path: "beta/b.txt"),
      IndexedFile(path: "alpha/z.txt"), IndexedFile(path: "a.txt")
    ])
    let rows = tree.rows(query: "", expandedDirectories: [])
    #expect(rows.map(\.path) == ["alpha", "beta", "a.txt", "z.txt"], "folder-first deterministic order failed: \(rows.map(\.path))")
  }

  @Test("File tree only shows expanded descendants")
  func fileTreeOnlyShowsExpandedDescendants() throws {
    let tree = FileTree(files: [IndexedFile(path: "Sources/Vox/App.swift")])
    let collapsed = tree.rows(query: "", expandedDirectories: [])
    let expanded = tree.rows(query: "", expandedDirectories: ["Sources", "Sources/Vox"])
    #expect(
      collapsed.map(\.path) == ["Sources"]
        && expanded.map(\.path) == ["Sources", "Sources/Vox", "Sources/Vox/App.swift"],
      "tree expansion is not respected")
  }

  @Test("File tree search includes and expands ancestors")
  func fileTreeSearchIncludesAndExpandsAncestors() throws {
    let tree = FileTree(files: [IndexedFile(path: "Sources/Vox/PalettePanel.swift")])
    let rows = tree.rows(query: "palette", expandedDirectories: [])
    #expect(
      rows.map(\.path) == ["Sources", "Sources/Vox", "Sources/Vox/PalettePanel.swift"]
        && rows.dropLast().allSatisfy(\.isExpanded),
      "search did not reveal the matched file's ancestors")
  }

  @Test("File tree search excludes unmatched branches")
  func fileTreeSearchExcludesUnmatchedBranches() throws {
    let tree = FileTree(files: [
      IndexedFile(path: "Sources/Vox/App.swift"), IndexedFile(path: "Tests/TreeTests.swift")
    ])
    let rows = tree.rows(query: "tree", expandedDirectories: ["Sources", "Tests"])
    #expect(rows.map(\.path) == ["Tests", "Tests/TreeTests.swift"], "search retained unmatched tree branches: \(rows.map(\.path))")
  }

  @Test("File tree rejects unsafe relative paths")
  func fileTreeRejectsUnsafeRelativePaths() throws {
    let tree = FileTree(files: [
      IndexedFile(path: "../secret"), IndexedFile(path: "/absolute"),
      IndexedFile(path: "safe/file.txt"), IndexedFile(path: "bad//file.txt")
    ])
    let rows = tree.rows(query: "", expandedDirectories: ["safe"])
    #expect(rows.map(\.path) == ["safe", "safe/file.txt"], "tree accepted a path outside its relative-path contract")
  }

  @Test("File tree rows distinguish directories from files")
  func fileTreeRowsDistinguishDirectoriesFromFiles() throws {
    let tree = FileTree(files: [IndexedFile(path: "dir/file.txt")])
    let rows = tree.rows(query: "", expandedDirectories: ["dir"])
    #expect(
      rows.count == 2 && rows[0].kind == .directory && rows[0].file == nil
        && rows[1].kind == .file && rows[1].file?.path == "dir/file.txt"
        && rows[0].id != rows[1].id,
      "directory and file row contracts overlap")
  }

  // MARK: M3 Orca アダプタ（`orca worktree ps --json`）

  @Test("Orca worktree JSON yields the only active local path")
  func orcaWorktreeJSONYieldsTheOnlyActiveLocalPath() throws {
    let json = """
      {"ok":true,"result":{"worktrees":[
        {"path":"/fixtures/voice","isActive":true,"isArchived":false,
         "hostId":null,"terminalPlatform":null,"workspaceKind":"folder-workspace"}],
        "totalCount":1,"truncated":false}}
      """
    #expect(OrcaWorktreeList.activePath(fromJSON: Data(json.utf8)) == "/fixtures/voice", "active worktree path を取れない")
  }

  @Test("Orca worktree JSON ignores newer inactive rows")
  func orcaWorktreeJSONIgnoresNewerInactiveRows() throws {
    let json = """
      {"ok":true,"result":{"worktrees":[
        {"path":"/active","isActive":true,"isArchived":false,"hostId":"local"},
        {"path":"/noisy-newer","isActive":false,"isArchived":false,"lastOutputAt":999999}],
        "truncated":false}}
      """
    #expect(OrcaWorktreeList.activePath(fromJSON: Data(json.utf8)) == "/active", "inactive row を active target として採った")
  }

  @Test("Orca worktree JSON rejects ambiguous active rows")
  func orcaWorktreeJSONRejectsAmbiguousActiveRows() throws {
    let json = #"{"ok":true,"result":{"worktrees":["#
      + #"{"path":"/a","isActive":true,"isArchived":false},"#
      + #"{"path":"/b","isActive":true,"isArchived":false}"#
      + #"],"truncated":false}}"#
    #expect(OrcaWorktreeList.activePath(fromJSON: Data(json.utf8)) == nil, "複数の active worktree から1つを推測した")
  }

  @Test("Orca worktree JSON rejects missing or invalid active rows")
  func orcaWorktreeJSONRejectsMissingOrInvalidActiveRows() throws {
    let fixtures = [
      #"{"ok":true,"result":{"worktrees":[],"truncated":false}}"#,
      #"{"ok":true,"result":{"worktrees":[{"path":"/inactive","isActive":false,"isArchived":false}],"truncated":false}}"#,
      #"{"ok":true,"result":{"worktrees":[{"path":"","isActive":true,"isArchived":false}],"truncated":false}}"#,
      #"{"ok":true,"result":{"worktrees":[{"path":"relative/path","isActive":true,"isArchived":false}],"truncated":false}}"#,
      #"{"ok":true,"result":{"worktrees":[{"path":"/partial","isActive":true,"isArchived":false}],"truncated":true}}"#,
      #"{"ok":true,"result":{"worktrees":[{"path":"/missing-truncated","isActive":true,"isArchived":false}]}}"#,
      #"{"ok":false,"result":{"worktrees":[{"path":"/a","isActive":true,"isArchived":false}],"truncated":false}}"#,
      "not json"
    ]
    for json in fixtures {
      #expect(
        OrcaWorktreeList.activePath(fromJSON: Data(json.utf8)) == nil,
        "invalid worktree response を採用した: \(json)")
    }
  }

  @Test("Orca worktree JSON rejects remote and archived rows")
  func orcaWorktreeJSONRejectsRemoteAndArchivedRows() throws {
    let fixtures = [
      #"{"ok":true,"result":{"worktrees":[{"path":"/remote","isActive":true,"isArchived":false,"hostId":"remote-1"}],"truncated":false}}"#,
      #"{"ok":true,"result":{"worktrees":[{"path":"/old","isActive":true,"isArchived":true,"hostId":"local"}],"truncated":false}}"#
    ]
    for json in fixtures {
      #expect(
        OrcaWorktreeList.activePath(fromJSON: Data(json.utf8)) == nil,
        "remote/archived worktree を採用した")
    }
  }

  @Test("Orca worktree JSON accepts local git and folder workspaces")
  func orcaWorktreeJSONAcceptsLocalGitAndFolderWorkspaces() throws {
    let fixtures = [
      (
        #"{"ok":true,"result":{"worktrees":[{"path":"/git","isActive":true,"isArchived":false,"#
          + #""hostId":"local","workspaceKind":"git"}],"truncated":false}}"#, "/git"),
      (
        #"{"ok":true,"result":{"worktrees":[{"path":"/folder","isActive":true,"isArchived":false,"#
          + #""hostId":null,"terminalPlatform":null,"workspaceKind":"folder-workspace"}],"#
          + #""truncated":false}}"#, "/folder")
    ]
    for (json, expected) in fixtures {
      #expect(
        OrcaWorktreeList.activePath(fromJSON: Data(json.utf8)) == expected,
        "local workspace kind を拒否した: \(expected)")
    }
  }

  @Test("Ps output yields the last process ID")
  func psOutputYieldsTheLastProcessID() throws {
    let output = " 1234 login\n 5678 zsh\n 9012 claude\n"
    #expect(ProcessListParser.foregroundProcessID(fromPsOutput: output) == 9012, "最前景プロセスの pid が違う")
  }
}

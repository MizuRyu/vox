// ADR-015 方式 A。Zed の workspace DB の読み取り。Zed が入っていない環境でも回るよう、
// 同じスキーマの SQLite を検査の中で作って読む（実物の DB には触らない）。

import Foundation
import SQLite3
import Testing
@testable import VoxApp
import VoxCore

@Suite("Palette: Zed の workspace DB")
struct ZedWorkspaceReaderTests {
  /// 実物と同じ 3 つの表。workspace 13 のほうが timestamp は新しい。
  private static let schema = """
    CREATE TABLE workspaces (
      workspace_id INTEGER PRIMARY KEY, paths TEXT, timestamp TEXT NOT NULL) STRICT;
    INSERT INTO workspaces (workspace_id, paths, timestamp) VALUES
      (7,  '/Users/me/projects/front',  '2026-09-20 10:00:00'),
      (13, '/Users/me/projects/newest', '2026-09-23 12:00:00'),
      (21, '/Users/me/projects/multi' || char(10) || '/Users/me/projects/second',
           '2026-09-21 10:00:00'),
      (22, '', '2026-09-22 10:00:00');
    CREATE TABLE kv_store (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
    CREATE TABLE scoped_kv_store (
      namespace TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY (namespace, key)) STRICT;
    INSERT INTO scoped_kv_store (namespace, key, value) VALUES
      ('multi_workspace_state', '4294967297', '{"active_workspace_id":7}'),
      ('multi_workspace_state', '4294967298', '{"active_workspace_id":13}'),
      ('multi_workspace_state', '4294967299', '{"active_workspace_id":21}'),
      ('multi_workspace_state', '4294967300', '{"active_workspace_id":22}');
    """

  /// `sql` を流した DB を一時ディレクトリに作り、書き込み側の接続を開いたまま body に渡す。
  /// why: WAL の DB を読み取り専用で読めることを見たいので、-wal と -shm を生かしておく。
  private func withDatabase(_ sql: String, _ body: (String) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vox-zed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("db.sqlite").path
    var writer: OpaquePointer?
    defer {
      sqlite3_close(writer)
      try? FileManager.default.removeItem(at: directory)
    }
    let opened = sqlite3_open_v2(
      path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    try #require(opened == SQLITE_OK, "fixture の DB を作れない")
    let script = "PRAGMA journal_mode=WAL;" + sql
    try #require(
      sqlite3_exec(writer, script, nil, nil, nil) == SQLITE_OK,
      "fixture の SQL が通らない: \(String(cString: sqlite3_errmsg(writer)))")
    try body(path)
  }

  private func frontmostRoot(in path: String) -> String? {
    ZedWorkspaceReader.frontmostRoot(
      databasePath: path,
      deadline: ContinuousClock.now.advanced(
        by: .milliseconds(PaletteTargetResolver.timeoutMilliseconds)))
  }

  private static func stack(_ windowIDs: String) -> String {
    "INSERT INTO kv_store (key, value) VALUES ('session_window_stack', '\(windowIDs)');"
  }

  @Test("The frontmost window wins over the workspace with the newest timestamp")
  func theFrontmostWindowWinsOverTheWorkspaceWithTheNewestTimestamp() throws {
    try withDatabase(Self.schema + Self.stack("[4294967297,4294967298]")) { path in
      #expect(
        frontmostRoot(in: path) == "/Users/me/projects/front",
        "焦点順の先頭ではなく別のウィンドウの workspace を返した: \(frontmostRoot(in: path) ?? "nil")")
    }
  }

  @Test("A multi root workspace resolves to its first path")
  func aMultiRootWorkspaceResolvesToItsFirstPath() throws {
    try withDatabase(Self.schema + Self.stack("[4294967299]")) { path in
      #expect(frontmostRoot(in: path) == "/Users/me/projects/multi", "複数ルートの先頭を採っていない")
    }
  }

  @Test("A workspace without paths has no target")
  func aWorkspaceWithoutPathsHasNoTarget() throws {
    try withDatabase(Self.schema + Self.stack("[4294967300]")) { path in
      #expect(frontmostRoot(in: path) == nil, "paths が空の workspace を対象にした")
    }
  }

  /// 古い Zed とマルチウィンドウ状態を書いたことのないセッション。timestamp 最新には後退しない。
  @Test("A database without the focus keys has no target")
  func aDatabaseWithoutTheFocusKeysHasNoTarget() throws {
    try withDatabase(Self.schema) { path in
      #expect(frontmostRoot(in: path) == nil, "焦点順が無い DB で timestamp 最新に後退した")
    }
    try withDatabase(Self.schema + Self.stack("[4294967399]")) { path in
      #expect(frontmostRoot(in: path) == nil, "状態の無いウィンドウ id から workspace を作った")
    }
  }

  @Test("A missing or foreign database has no target")
  func aMissingOrForeignDatabaseHasNoTarget() throws {
    #expect(frontmostRoot(in: "/nonexistent/zed/db.sqlite") == nil, "無い DB から対象を作った")
    try withDatabase("CREATE TABLE other (id INTEGER PRIMARY KEY) STRICT;") { path in
      #expect(frontmostRoot(in: path) == nil, "スキーマが違う DB から対象を作った")
    }
  }

  @Test("The database path follows the release channel")
  func theDatabasePathFollowsTheReleaseChannel() throws {
    let path = ZedWorkspaceReader.databasePath(channel: "preview")
    #expect(path.hasPrefix("/"), "チルダを展開していない: \(path)")
    #expect(
      path.hasSuffix("Library/Application Support/Zed/db/0-preview/db.sqlite"),
      "channel ごとのディレクトリを指していない: \(path)")
  }
}

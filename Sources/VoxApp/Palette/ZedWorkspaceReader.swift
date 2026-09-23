// ADR-015 方式 A。Zed の workspace DB を読み取り専用で開き、最前面のウィンドウが
// 開いているプロジェクトのルートを返す。行の解釈は VoxCore.ZedWorkspace。
//
//   kv_store.session_window_stack の先頭 → scoped_kv_store(multi_workspace_state) の
//   active_workspace_id → workspaces.paths の先頭
//
// どこかで欠けたら nil を返し、呼び出し側が次の方式に落ちる（案内は出さない）。

import Foundation
import SQLite3
import VoxCore

enum ZedWorkspaceReader {
  static func frontmostRoot(channel: String, deadline: ContinuousClock.Instant) -> String? {
    frontmostRoot(databasePath: databasePath(channel: channel), deadline: deadline)
  }

  /// 検査は fixture の DB を渡す。
  static func frontmostRoot(databasePath: String, deadline: ContinuousClock.Instant) -> String? {
    guard let database = open(databasePath) else { return nil }
    defer { sqlite3_close(database) }
    guard
      let stack = firstColumn(
        database, "SELECT value FROM kv_store WHERE key = 'session_window_stack'",
        before: deadline),
      let window = ZedWorkspace.frontmostWindowID(sessionWindowStack: stack),
      let state = firstColumn(
        database,
        """
        SELECT value FROM scoped_kv_store
        WHERE namespace = 'multi_workspace_state' AND key = '\(window)'
        """, before: deadline),
      let workspace = ZedWorkspace.activeWorkspaceID(multiWorkspaceState: state),
      // why: リモート接続の workspace の paths は接続先のパス。同じ絶対パスが手元にあると
      // 別のフォルダを検索対象にしてしまうので、ローカルの workspace だけを見る。
      let paths = firstColumn(
        database,
        """
        SELECT paths FROM workspaces
        WHERE workspace_id = \(workspace) AND remote_connection_id IS NULL
        """, before: deadline)
    else {
      voxLog("palette_target zed_unavailable")
      return nil
    }
    return ZedWorkspace.firstRoot(paths: paths)
  }

  static func databasePath(channel: String) -> String {
    let path = "~/Library/Application Support/Zed/db/0-\(channel)/db.sqlite"
    return (path as NSString).expandingTildeInPath
  }

  /// why: Zed が書いている最中の DB（WAL）を触るので、読み取り専用で開き、
  /// 書き込みも `PRAGMA` も一切しない。
  private static func open(_ path: String) -> OpaquePointer? {
    var database: OpaquePointer?
    let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
    guard opened == SQLITE_OK, let database else {
      sqlite3_close(database)
      return nil
    }
    return database
  }

  /// 期限は問い合わせごとに見る（`busy_timeout` はロック待ちの上限でしかない）。
  /// why: 埋め込む値は `Int64` に変換済みなので、SQL に文字列が入る経路がない。
  private static func firstColumn(
    _ database: OpaquePointer, _ sql: String, before deadline: ContinuousClock.Instant
  ) -> String? {
    let remaining = remainingMilliseconds(until: deadline)
    guard remaining > 0 else { return nil }
    sqlite3_busy_timeout(database, remaining)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
    else { return nil }
    let bytes = Int(sqlite3_column_bytes(statement, 0))
    return String(bytes: UnsafeRawBufferPointer(start: text, count: bytes), encoding: .utf8)
  }

  /// 期限を過ぎていたら 0（SQLite は 0 以下でロックを待たずに戻る）。
  private static func remainingMilliseconds(until deadline: ContinuousClock.Instant) -> Int32 {
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let milliseconds =
      remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000
    return Int32(clamping: max(0, milliseconds))
  }
}

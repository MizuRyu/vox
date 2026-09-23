// ADR-015 方式 A。Zed の workspace DB に入っている行の解釈。
// SQLite を開くのは Vox 側（ZedWorkspaceReader）。ここには JSON と改行区切りの読み方だけを置く。

import Foundation

public enum ZedWorkspace {
  /// `kv_store` の `session_window_stack`。JSON 配列の先頭が最前面のウィンドウ。
  /// why: ウィンドウ id は 32bit に収まらない値が入る。
  public static func frontmostWindowID(sessionWindowStack value: String) -> Int64? {
    guard let data = value.data(using: .utf8),
      let stack = try? JSONDecoder().decode([Int64].self, from: data)
    else { return nil }
    return stack.first
  }

  /// `scoped_kv_store`（namespace `multi_workspace_state`）のウィンドウ 1 つ分の状態。
  public static func activeWorkspaceID(multiWorkspaceState value: String) -> Int64? {
    struct State: Decodable {
      let activeWorkspaceID: Int64?

      enum CodingKeys: String, CodingKey {
        case activeWorkspaceID = "active_workspace_id"
      }
    }
    guard let data = value.data(using: .utf8),
      let state = try? JSONDecoder().decode(State.self, from: data)
    else { return nil }
    return state.activeWorkspaceID
  }

  /// `workspaces.paths`。複数ルートは改行区切りで、索引は 1 ルートなので先頭を採る。
  /// why: フォルダ名は末尾に空白を持てるので、空行を飛ばすだけで行そのものは削らない。
  public static func firstRoot(paths: String) -> String? {
    for line in paths.split(separator: "\n") {
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      return line.hasPrefix("/") ? String(line) : nil
    }
    return nil
  }
}

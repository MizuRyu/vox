// R15 / ADR-011。パレットの検索対象をトグル ON 時の前面アプリから導く。
// プロセス実行と AppleScript は Vox 側（PaletteTargetResolver）に置き、
// ここには「どのアダプタを使うか」と「出力の解釈」だけを置く。

import Foundation

/// 計測 JSONL の `palette_target_source`。特定できなかった回は null（= nil）。
public enum PaletteTargetSource: String, Sendable, Equatable {
  case orca
  case terminal
  case fallback
  /// T38-a。候補行から同一リポジトリの他の worktree に切り替えた回。
  case worktree
}

public struct PaletteTarget: Sendable, Equatable {
  /// 検索対象のルート（リポジトリのルート、またはフォールバックのディレクトリ）。絶対パス。
  public let root: String
  public let source: PaletteTargetSource

  public init(root: String, source: PaletteTargetSource) {
    self.root = root
    self.source = source
  }
}

public enum PaletteTargetAdapter: Sendable, Equatable {
  case orca
  case terminalApp
  case none

  /// トグル ON 時に固定した bundle identifier からアダプタを選ぶ。
  public static func forBundleIdentifier(_ identifier: String?) -> PaletteTargetAdapter {
    switch identifier {
    case "com.stablyai.orca": .orca
    case "com.apple.Terminal": .terminalApp
    default: .none
    }
  }
}

/// `orca worktree ps --json` の解釈。
public enum OrcaWorktreeList {
  private struct Response: Decodable {
    struct Worktree: Decodable {
      let path: String
      let isActive: Bool
      let isArchived: Bool
      let hostId: String?
    }
    struct Result: Decodable {
      let worktrees: [Worktree]
      let truncated: Bool
    }
    let ok: Bool
    let result: Result
  }

  /// UI でアクティブな、ローカルかつ非 archived の worktree root。
  public static func activePath(fromJSON data: Data) -> String? {
    guard let response = try? JSONDecoder().decode(Response.self, from: data),
      response.ok, !response.result.truncated
    else { return nil }
    let active = response.result.worktrees.filter(\.isActive)
    guard active.count == 1, let worktree = active.first,
      !worktree.isArchived,
      worktree.hostId == nil || worktree.hostId == "local",
      !worktree.path.isEmpty,
      (worktree.path as NSString).isAbsolutePath
    else { return nil }
    return worktree.path
  }
}

/// T38-a。パレットの候補行に出す、同一リポジトリの他の worktree。
public struct WorktreeCandidate: Sendable, Equatable {
  public let path: String
  public let branch: String?

  public init(path: String, branch: String?) {
    self.path = path
    self.branch = branch
  }
}

/// `git worktree list --porcelain` の解釈。パスの存在確認は Vox 側で行う。
public enum GitWorktreeList {
  /// 空行区切りのレコードから、切り替え先にできる worktree だけを git の出力順で返す。
  /// bare・detached・prunable は切り替えても索引を作れない、または消えかけているので外す。
  public static func candidates(fromPorcelain output: String, excluding currentRoot: String)
    -> [WorktreeCandidate] {
    let current = normalized(currentRoot)
    var candidates: [WorktreeCandidate] = []
    var path: String?
    var branch: String?
    var excluded = false

    func flush() {
      defer {
        path = nil
        branch = nil
        excluded = false
      }
      guard let path, !excluded, normalized(path) != current else { return }
      candidates.append(WorktreeCandidate(path: path, branch: branch))
    }

    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.isEmpty {
        flush()
        continue
      }
      if let value = value(of: "worktree", in: text) {
        // 直前のレコードが空行で閉じられていない出力にも耐える。
        flush()
        path = value
      } else if let value = value(of: "branch", in: text) {
        branch = value.hasPrefix("refs/heads/")
          ? String(value.dropFirst("refs/heads/".count)) : value
      } else if text == "bare" || text == "detached" || text == "prunable"
        || text.hasPrefix("prunable ") {
        excluded = true
      }
    }
    flush()
    return candidates
  }

  private static func value(of key: String, in line: String) -> String? {
    guard line.hasPrefix(key + " ") else { return nil }
    return String(line.dropFirst(key.count + 1))
  }

  private static func normalized(_ path: String) -> String {
    var result = path
    while result.count > 1, result.hasSuffix("/") { result.removeLast() }
    return result
  }
}

/// Terminal.app のアダプタ用。`ps -t <tty> -o pid=,comm=` の解釈。
public enum ProcessListParser {
  /// 最後の行（= 最も新しく起動したプロセス）の pid を最前景として扱う。
  public static func foregroundProcessID(fromPsOutput output: String) -> Int32? {
    let lines = output.split(separator: "\n").map(String.init)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let last = lines.last, let pidText = last.split(separator: " ").first,
      let pid = Int32(pidText)
    else { return nil }
    return pid
  }
}

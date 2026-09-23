// R15 / ADR-011 / ADR-015。パレットの検索対象をトグル ON 時の前面アプリから導く。
// プロセス実行と DB 読み取りは Vox 側（PaletteTargetResolver）に置き、
// ここには「どのアダプタを使うか」と「出力の解釈」だけを置く。

import Foundation

/// 計測 JSONL の `palette_target_source`。特定できなかった回は null（= nil）。
/// `worktree`（T38-a）と `recent` / `manual`（T23）は選び直した回。`recent` は ADR-015 方式 C にも使う。
public enum PaletteTargetSource: String, Sendable, Equatable {
  case orca
  case zed
  case terminal
  case fallback
  case worktree
  case recent
  case manual

  /// why: ヘッダで色を変えるのは前面アプリから決まらなかった回だけ。選び直した回は警告しない。
  public var resolvedFromFrontmostApp: Bool {
    switch self {
    case .orca, .zed, .terminal: true
    case .fallback, .worktree, .recent, .manual: false
    }
  }
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

/// ADR-015。トグル ON 時に固定した前面アプリから、検索対象の決め方を選ぶ。
public enum PaletteTargetAdapter: Sendable, Equatable {
  case orca
  /// Zed は channel ごとに DB のディレクトリが違う（`db/0-<channel>`）。
  case zed(channel: String)
  /// ターミナルはどれも同じ手順（子孫プロセスの tty → cwd → git のルート）。
  case terminal
  case none

  private static let table: [String: PaletteTargetAdapter] = [
    "com.stablyai.orca": .orca,
    "dev.zed.zed": .zed(channel: "stable"),
    "dev.zed.zed-preview": .zed(channel: "preview"),
    "dev.zed.zed-nightly": .zed(channel: "nightly"),
    "com.apple.terminal": .terminal,
    "com.mitchellh.ghostty": .terminal,
    "com.cmuxterm.app": .terminal,
    "com.googlecode.iterm2": .terminal,
    "dev.warp.warp-stable": .terminal
  ]

  /// 対応アプリを足すのは上の表に 1 行。
  /// why: LaunchServices は同じアプリを `dev.warp.warp-stable` と `dev.warp.Warp-Stable` の
  /// 両方で持つので、引き当てで大文字小文字を見ない。
  public static func forBundleIdentifier(_ identifier: String?) -> PaletteTargetAdapter {
    guard let identifier else { return .none }
    return table[identifier.lowercased()] ?? .none
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

/// ターミナルのアダプタ用。`ps -t <tty> -o pid=,comm=` の解釈。
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

/// ADR-015 方式 B。`ps -axo pid,ppid,tty,comm` の解釈。
/// why: どのターミナルもシェルを自分の子孫として起こすので、子孫の tty を集めれば
/// 開いているタブが出る。アプリごとの照会（AppleScript・専用 API）が要らない。
public enum ProcessTree {
  /// `rootPID` の子孫が使っている tty デバイス名（`ttys000` の形）を ps の順で 1 度ずつ。
  public static func terminalDevices(fromPsOutput output: String, ofDescendantsOf rootPID: Int32)
    -> [String] {
    let rows = rows(in: output)
    var children: [Int32: [Int32]] = [:]
    for row in rows where row.parentPID != row.pid {
      children[row.parentPID, default: []].append(row.pid)
    }
    var descendants: Set<Int32> = []
    var pending = children[rootPID] ?? []
    while let pid = pending.popLast() {
      guard descendants.insert(pid).inserted else { continue }
      pending.append(contentsOf: children[pid] ?? [])
    }
    var devices: [String] = []
    for row in rows where descendants.contains(row.pid) {
      guard let device = row.device, !devices.contains(device) else { continue }
      devices.append(device)
    }
    return devices
  }

  private struct Row {
    let pid: Int32
    let parentPID: Int32
    let device: String?
  }

  /// 見出し行（`PID PPID TTY COMM`）は pid が数値でないので落ちる。
  private static func rows(in output: String) -> [Row] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 3, let pid = Int32(fields[0]), let parentPID = Int32(fields[1])
      else { return nil }
      let device = String(fields[2])
      return Row(pid: pid, parentPID: parentPID, device: device == "??" ? nil : device)
    }
  }
}

/// ADR-015 方式 B。tty とその `/dev/<name>` の mtime。mtime を取るのは Vox 側。
public struct TerminalDevice: Sendable, Equatable {
  public let name: String
  public let modifiedAt: Date

  public init(name: String, modifiedAt: Date) {
    self.name = name
    self.modifiedAt = modifiedAt
  }

  /// 最後に書き込みがあった tty を「利用者が見ているタブ」とみなす。
  /// 同じ時刻なら名前で決める（同じ入力なら同じ答えにする）。
  public static func mostRecentlyUsed(_ devices: [TerminalDevice]) -> String? {
    devices.max {
      $0.modifiedAt == $1.modifiedAt ? $0.name > $1.name : $0.modifiedAt < $1.modifiedAt
    }?.name
  }
}

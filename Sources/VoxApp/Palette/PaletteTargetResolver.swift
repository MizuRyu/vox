// R15 / ADR-011 / ADR-015。パレットの検索対象を、トグル ON 時に固定した targetApp から導く。
//
//   Orca       → `orca worktree ps --json` の UI-active local worktree path
//   Zed        → workspace DB の最前面ウィンドウが開いているプロジェクト
//   ターミナル → 子孫プロセスの tty → その tty の最前景プロセス → cwd → git のルート
//   それ以外   → `--repo` → 最近使ったフォルダ → カレントディレクトリ
//
// アダプタはパレットを開いた瞬間に非同期で走らせ、500ms 以内に返らなければフォールバックする。
// 解釈（JSON / ps / DB の行）は VoxCore 側でテストしている。

import Darwin
import Foundation
import VoxCore

enum PaletteTargetResolver {
  /// アダプタの待ち上限（指示書「500ms 以内に来なければフォールバック」）。
  static let timeoutMilliseconds = 500

  /// `fallbackRepositories` は `--repo` の指定。`recentFolder` は最近使ったフォルダの最新（T23）。
  /// 対象を 1 つも作れなかったときだけ nil（ヘッダに「対象を特定できず」を出す側の判断材料）。
  static func resolve(
    bundleIdentifier: String?, processID: Int32?, fallbackRepositories: [String],
    recentFolder: String?
  ) async -> PaletteTarget? {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    let target =
      frontmostAppTarget(
        bundleIdentifier: bundleIdentifier, processID: processID, deadline: deadline)
      ?? fallbackTarget(
        repositories: fallbackRepositories, recentFolder: recentFolder,
        allowCurrentDirectory: VoxConfig.allowCurrentDirectoryFallback)
    guard let target else {
      voxLog("palette_target source=none")
      return nil
    }
    voxLog(
      "palette_target source=\(target.source.rawValue) root=\(voxLoggable(path: target.root))")
    return target
  }

  private static func frontmostAppTarget(
    bundleIdentifier: String?, processID: Int32?, deadline: ContinuousClock.Instant
  ) -> PaletteTarget? {
    switch PaletteTargetAdapter.forBundleIdentifier(bundleIdentifier) {
    case .orca:
      orcaWorktreePath(deadline: deadline).map { PaletteTarget(root: $0, source: .orca) }
    case .zed(let channel):
      zedProjectRoot(channel: channel, deadline: deadline)
        .map { PaletteTarget(root: $0, source: .zed) }
    case .terminal:
      processID.flatMap { terminalRepositoryRoot(of: $0, deadline: deadline) }
        .map { PaletteTarget(root: $0, source: .terminal) }
    case .none:
      nil
    }
  }

  private static func orcaWorktreePath(deadline: ContinuousClock.Instant) -> String? {
    guard
      let output = Shell.run(
        "orca", ["worktree", "ps", "--json"], deadline: deadline),
      output.succeeded
    else { return nil }
    guard let path = OrcaWorktreeList.activePath(fromJSON: Data(output.standardOutput.utf8))
    else {
      voxLog("palette_target orca_parse_failed")
      return nil
    }
    guard isDirectory(path) else {
      voxLog("palette_target orca_path_unavailable")
      return nil
    }
    return path
  }

  /// why: Zed が見せているのは workspace そのものなので、`git rev-parse` でリポジトリの
  /// ルートまで広げない（サブディレクトリを開いている回に対象が勝手に広がる）。
  private static func zedProjectRoot(channel: String, deadline: ContinuousClock.Instant) -> String? {
    guard let root = ZedWorkspaceReader.frontmostRoot(channel: channel, deadline: deadline),
      isDirectory(root)
    else { return nil }
    return root
  }

  // MARK: ターミナル

  /// ADR-015 方式 B。前面アプリの子孫プロセスのうち、最後に書き込みがあった tty を使う。
  private static func terminalRepositoryRoot(
    of processID: Int32, deadline: ContinuousClock.Instant
  ) -> String? {
    guard
      let tree = Shell.run("ps", ["-axo", "pid,ppid,tty,comm"], deadline: deadline),
      tree.succeeded
    else { return nil }
    let devices = ProcessTree.terminalDevices(
      fromPsOutput: tree.standardOutput, ofDescendantsOf: processID)
    guard let device = TerminalDevice.mostRecentlyUsed(devices.compactMap(device(named:)))
    else { return nil }

    guard
      let processes = Shell.run("ps", ["-t", device, "-o", "pid=,comm="], deadline: deadline),
      processes.succeeded,
      let pid = ProcessListParser.foregroundProcessID(fromPsOutput: processes.standardOutput),
      let cwd = workingDirectory(of: pid)
    else { return nil }
    return repositoryRoot(containing: cwd, deadline: deadline) ?? cwd
  }

  /// mtime を取れない tty は候補から落とす（閉じかけのタブ）。
  private static func device(named name: String) -> TerminalDevice? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/\(name)")
    guard let modifiedAt = attributes?[.modificationDate] as? Date else { return nil }
    return TerminalDevice(name: name, modifiedAt: modifiedAt)
  }

  /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` で cwd を取る（ADR-011）。
  static func workingDirectory(of pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = MemoryLayout<proc_vnodepathinfo>.size
    let written = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
    }
    guard written == Int32(size) else { return nil }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty ? nil : path
  }

  // MARK: 共通

  /// cwd そのものではなくリポジトリのルートを対象にする（ADR-011）。
  static func repositoryRoot(
    containing directory: String, deadline: ContinuousClock.Instant? = nil
  ) -> String? {
    guard
      let output = Shell.run(
        "git", ["rev-parse", "--show-toplevel"], currentDirectory: directory,
        deadline: deadline),
      output.succeeded
    else { return nil }
    let root = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return root.isEmpty ? nil : root
  }

  /// why: T38-a。git は消えたディレクトリの worktree も出力に残すので、存在するものだけ候補にする。
  static func worktreeCandidates(root: String, deadline: ContinuousClock.Instant)
    -> [WorktreeCandidate] {
    guard
      let output = Shell.run(
        "git", ["-C", root, "worktree", "list", "--porcelain"], deadline: deadline),
      output.succeeded
    else { return [] }
    return GitWorktreeList.candidates(fromPorcelain: output.standardOutput, excluding: root)
      .filter { isDirectory($0.path) }
  }

  /// ADR-015 方式 C。`--repo` → 最近使ったフォルダ → カレントディレクトリ。
  private static func fallbackTarget(
    repositories: [String], recentFolder: String?, allowCurrentDirectory: Bool
  ) -> PaletteTarget? {
    for repository in repositories {
      let expanded = (repository as NSString).expandingTildeInPath
      if isDirectory(expanded) { return PaletteTarget(root: expanded, source: .fallback) }
    }
    if let recentFolder, isDirectory(recentFolder) {
      return PaletteTarget(root: recentFolder, source: .recent)
    }
    guard allowCurrentDirectory else { return nil }
    let current = FileManager.default.currentDirectoryPath
    return current.isEmpty ? nil : PaletteTarget(root: current, source: .fallback)
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

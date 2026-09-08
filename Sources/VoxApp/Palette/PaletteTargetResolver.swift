// R15 / ADR-011。パレットの検索対象を、トグル ON 時に固定した targetApp から導く。
//
//   com.stablyai.orca  → `orca worktree ps --json` の UI-active local worktree path
//   com.apple.Terminal → AppleScript で tty → ps で最前景プロセス → proc_pidinfo で cwd → git のルート
//   それ以外            → 設定のリポジトリ（--repo）、無ければカレントディレクトリ
//
// アダプタはパレットを開いた瞬間に非同期で走らせ、500ms 以内に返らなければフォールバックする。
// 解釈（JSON / ps の出力）は VoxCore 側でテストしている。

import Darwin
import Foundation
import VoxCore

enum PaletteTargetResolver {
  /// アダプタの待ち上限（指示書「500ms 以内に来なければフォールバック」）。
  static let timeoutMilliseconds = 500

  /// `fallbackRepositories` は `--repo` の指定。空ならカレントディレクトリ。
  /// 対象を 1 つも作れなかったときだけ nil（ヘッダに「対象を特定できず」を出す側の判断材料）。
  static func resolve(bundleIdentifier: String?, fallbackRepositories: [String]) async
    -> PaletteTarget? {
    let adapter = PaletteTargetAdapter.forBundleIdentifier(bundleIdentifier)
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    if adapter != .none, let root = adapterRoot(adapter, deadline: deadline) {
      let source: PaletteTargetSource = adapter == .orca ? .orca : .terminal
      voxLog("palette_target source=\(source.rawValue) root=\(voxLoggable(path: root))")
      return PaletteTarget(root: root, source: source)
    }
    guard
      let root = fallbackRoot(
        fallbackRepositories, allowCurrentDirectory: VoxConfig.allowCurrentDirectoryFallback)
    else {
      voxLog("palette_target source=none")
      return nil
    }
    voxLog("palette_target source=fallback root=\(voxLoggable(path: root))")
    return PaletteTarget(root: root, source: .fallback)
  }

  private static func adapterRoot(
    _ adapter: PaletteTargetAdapter, deadline: ContinuousClock.Instant
  ) -> String? {
    switch adapter {
    case .orca: orcaWorktreePath(deadline: deadline)
    case .terminalApp: terminalAppRepositoryRoot(deadline: deadline)
    case .none: nil
    }
  }

  // MARK: Orca

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
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      voxLog("palette_target orca_path_unavailable")
      return nil
    }
    return path
  }

  // MARK: Terminal.app

  private static func terminalAppRepositoryRoot(deadline: ContinuousClock.Instant) -> String? {
    let script = "tell application \"Terminal\" to tty of selected tab of front window"
    guard let ttyOutput = Shell.run("osascript", ["-e", script], deadline: deadline),
      ttyOutput.succeeded
    else {
      return nil
    }
    let tty = ttyOutput.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard tty.hasPrefix("/dev/") else { return nil }
    let device = String(tty.dropFirst("/dev/".count))

    guard
      let psOutput = Shell.run(
        "ps", ["-t", device, "-o", "pid=,comm="], deadline: deadline),
      psOutput.succeeded,
      let pid = ProcessListParser.foregroundProcessID(fromPsOutput: psOutput.standardOutput),
      let cwd = workingDirectory(of: pid)
    else { return nil }
    return repositoryRoot(containing: cwd, deadline: deadline) ?? cwd
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

  /// T38-a。切り替え先に出す兄弟 worktree。消えたパスは候補から落とす。
  static func worktreeCandidates(root: String, deadline: ContinuousClock.Instant)
    -> [WorktreeCandidate] {
    guard
      let output = Shell.run(
        "git", ["-C", root, "worktree", "list", "--porcelain"], deadline: deadline),
      output.succeeded
    else { return [] }
    return GitWorktreeList.candidates(fromPorcelain: output.standardOutput, excluding: root)
      .filter { candidate in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
          && isDirectory.boolValue
      }
  }

  private static func fallbackRoot(
    _ repositories: [String], allowCurrentDirectory: Bool
  ) -> String? {
    for repository in repositories {
      let expanded = (repository as NSString).expandingTildeInPath
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
        isDirectory.boolValue {
        return expanded
      }
    }
    guard allowCurrentDirectory else { return nil }
    let current = FileManager.default.currentDirectoryPath
    return current.isEmpty ? nil : current
  }
}

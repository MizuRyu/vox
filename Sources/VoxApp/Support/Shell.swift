// パレットのアダプタと索引が使う外部コマンド実行。
// メインスレッドを止めないので、呼び出しは必ず detached な Task から行う。

import Foundation
import VoxCore

struct ShellOutput: Sendable {
  let standardOutput: String
  let standardError: String
  let exitCode: Int32

  var succeeded: Bool { exitCode == 0 }
}

enum Shell {
  /// PATH を明示する。GUI から起動されたときに /opt/homebrew/bin が入っていないことがある。
  static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  /// `executable` は絶対パスか、PATH から解決できる名前。見つからなければ nil。
  static func resolve(_ executable: String) -> String? {
    if executable.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
    }
    for directory in searchPath.split(separator: ":") {
      let candidate = "\(directory)/\(executable)"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// 同期実行。呼び出し側で detached Task に載せること。
  nonisolated static func run(
    _ executable: String, _ arguments: [String], currentDirectory: String? = nil,
    deadline: ContinuousClock.Instant? = nil
  ) -> ShellOutput? {
    guard let path = resolve(executable) else { return nil }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath
    let result = ProcessRunner.run(
      executable: path,
      arguments: arguments,
      currentDirectory: currentDirectory,
      environment: environment,
      deadline: deadline ?? ContinuousClock.now.advanced(by: .seconds(30)),
      outputLimit: 8 * 1024 * 1024)
    guard case .exited(let status) = result.termination else {
      // Keep diagnostics categorical: command output and filesystem paths can contain private text.
      voxLog("shell_failed reason=\(terminationLabel(result.termination))")
      return nil
    }
    // 非 UTF-8 の出力は置換文字で握りつぶさず失敗にする。呼び出し側には nil の経路（索引なら
    // ファイル走査へのフォールバック）が既にある。
    guard let standardOutput = String(bytes: result.standardOutput, encoding: .utf8),
      let standardError = String(bytes: result.standardError, encoding: .utf8)
    else {
      voxLog("shell_failed reason=not_utf8")
      return nil
    }
    return ShellOutput(
      standardOutput: standardOutput, standardError: standardError, exitCode: status)
  }

  private static func terminationLabel(_ termination: ProcessTermination) -> String {
    switch termination {
    case .exited: "exit"
    case .timedOut: "timeout"
    case .cancelled: "cancelled"
    case .outputLimitExceeded: "output_limit"
    case .launchFailed: "launch"
    }
  }
}

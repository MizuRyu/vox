import Darwin
import Foundation

public enum ProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case timedOut
  case cancelled
  case outputLimitExceeded
  case launchFailed
}

public struct ProcessResult: Sendable {
  public let standardOutput: Data
  public let standardError: Data
  public let termination: ProcessTermination
}

public enum ProcessRunner {
  public static func run(
    executable: String, arguments: [String], currentDirectory: String? = nil,
    environment: [String: String]? = nil, timeout: Duration, outputLimit: Int
  ) -> ProcessResult {
    run(
      executable: executable, arguments: arguments, currentDirectory: currentDirectory,
      environment: environment, deadline: ContinuousClock.now.advanced(by: timeout),
      outputLimit: outputLimit)
  }

  public static func run(
    executable: String, arguments: [String], currentDirectory: String? = nil,
    environment: [String: String]? = nil, deadline: ContinuousClock.Instant, outputLimit: Int
  ) -> ProcessResult {
    if Task.isCancelled { return empty(.cancelled) }
    if ContinuousClock.now >= deadline { return empty(.timedOut) }
    var outputFDs = [Int32](repeating: -1, count: 2)
    var errorFDs = [Int32](repeating: -1, count: 2)
    guard pipe(&outputFDs) == 0 else { return failed() }
    guard pipe(&errorFDs) == 0 else {
      close(outputFDs[0])
      close(outputFDs[1])
      return failed()
    }
    // 開いた 4 本をまとめて閉じる。子への引き渡し前の失敗経路はすべてここを通す。
    func closeAllPipes() {
      close(outputFDs[0])
      close(outputFDs[1])
      close(errorFDs[0])
      close(errorFDs[1])
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      closeAllPipes()
      return failed()
    }
    guard posix_spawnattr_init(&attributes) == 0 else {
      posix_spawn_file_actions_destroy(&actions)
      closeAllPipes()
      return failed()
    }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    guard
      prepareSpawn(
        actions: &actions, attributes: &attributes, outputFDs: outputFDs, errorFDs: errorFDs,
        currentDirectory: currentDirectory)
    else {
      closeAllPipes()
      return failed()
    }

    var pid: pid_t = 0
    let spawnStatus = spawnProcess(
      pid: &pid, executable: executable, arguments: arguments, environment: environment,
      actions: &actions, attributes: &attributes)
    close(outputFDs[1])
    close(errorFDs[1])
    guard spawnStatus == 0 else {
      close(outputFDs[0])
      close(errorFDs[0])
      return failed()
    }
    return collect(
      pid: pid, outputFD: outputFDs[0], errorFD: errorFDs[0], deadline: deadline,
      outputLimit: outputLimit)
  }

  /// 子の stdio 差し替えとプロセスグループ設定。1 つでも失敗したら以降は試さない。
  private static func prepareSpawn(
    actions: inout posix_spawn_file_actions_t?, attributes: inout posix_spawnattr_t?,
    outputFDs: [Int32], errorFDs: [Int32], currentDirectory: String?
  ) -> Bool {
    var setupStatus = "/dev/null".withCString {
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0)
    }
    if setupStatus == 0 {
      setupStatus = posix_spawn_file_actions_adddup2(&actions, outputFDs[1], STDOUT_FILENO)
    }
    if setupStatus == 0 {
      setupStatus = posix_spawn_file_actions_adddup2(&actions, errorFDs[1], STDERR_FILENO)
    }
    if setupStatus == 0 { setupStatus = posix_spawn_file_actions_addclose(&actions, outputFDs[0]) }
    if setupStatus == 0 { setupStatus = posix_spawn_file_actions_addclose(&actions, errorFDs[0]) }
    if setupStatus == 0 { setupStatus = posix_spawn_file_actions_addclose(&actions, outputFDs[1]) }
    if setupStatus == 0 { setupStatus = posix_spawn_file_actions_addclose(&actions, errorFDs[1]) }
    if let currentDirectory {
      if setupStatus == 0 {
        setupStatus = currentDirectory.withCString {
          posix_spawn_file_actions_addchdir(&actions, $0)
        }
      }
    }
    if setupStatus == 0 { setupStatus = posix_spawnattr_setpgroup(&attributes, 0) }
    if setupStatus == 0 {
      setupStatus = posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    }
    return setupStatus == 0
  }

  private static func spawnProcess(
    pid: inout pid_t, executable: String, arguments: [String], environment: [String: String]?,
    actions: inout posix_spawn_file_actions_t?, attributes: inout posix_spawnattr_t?
  ) -> Int32 {
    let argumentStrings = [executable] + arguments
    let environmentStrings =
      environment?.map { "\($0.key)=\($0.value)" }
      ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
    var argv = argumentStrings.map { $0.withCString(strdup) } + [nil]
    var envp = environmentStrings.map { $0.withCString(strdup) } + [nil]
    defer {
      for pointer in argv.dropLast() { free(pointer) }
      for pointer in envp.dropLast() { free(pointer) }
    }
    return executable.withCString {
      posix_spawn(&pid, $0, &actions, &attributes, &argv, &envp)
    }
  }

  /// 読み取り側 fd を所有し、子の終了まで読み切って結果にまとめる。
  private static func collect(
    pid: pid_t, outputFD: Int32, errorFD: Int32, deadline: ContinuousClock.Instant, outputLimit: Int
  ) -> ProcessResult {
    for fd in [outputFD, errorFD] {
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    defer {
      close(outputFD)
      close(errorFD)
    }
    var state = CollectorState()
    let limit = max(0, outputLimit)
    pump(&state, pid: pid, outputFD: outputFD, errorFD: errorFD, deadline: deadline, limit: limit)
    return finish(&state, pid: pid, outputFD: outputFD, errorFD: errorFD, limit: limit)
  }

  private struct CollectorState {
    var output = Data()
    var error = Data()
    var outputOpen = true
    var errorOpen = true
    var rootStatus: Int32?
    var forced: ProcessTermination?
  }

  private static func pump(
    _ state: inout CollectorState, pid: pid_t, outputFD: Int32, errorFD: Int32,
    deadline: ContinuousClock.Instant, limit: Int
  ) {
    while true {
      drainBoth(&state, outputFD: outputFD, errorFD: errorFD, limit: limit)
      // A descendant that inherited the pipes can hold them open long after the command is done,
      // so the root exit ends the run. Once reaped, never signal this numeric PID/group again,
      // which is why only the deadline and cancellation paths signal it.
      var status: Int32 = 0
      if waitpid(pid, &status, WNOHANG) == pid {
        state.rootStatus = status
        break
      }
      if state.forced == nil && Task.isCancelled { state.forced = .cancelled }
      if state.forced == nil && ContinuousClock.now >= deadline { state.forced = .timedOut }
      if state.forced != nil { break }
      waitForReadable(state, outputFD: outputFD, errorFD: errorFD)
    }
  }

  private static func finish(
    _ state: inout CollectorState, pid: pid_t, outputFD: Int32, errorFD: Int32, limit: Int
  ) -> ProcessResult {
    if state.forced != nil {
      // The group was created atomically; signal it before final wait/reap to avoid PID reuse.
      _ = Darwin.kill(-pid, SIGTERM)
      _ = Darwin.kill(-pid, SIGKILL)
    }
    if state.rootStatus == nil {
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
      state.rootStatus = status
    }
    drainBoth(&state, outputFD: outputFD, errorFD: errorFD, limit: limit)
    return ProcessResult(
      standardOutput: state.output, standardError: state.error,
      termination: state.forced ?? .exited(exitCode(from: state.rootStatus ?? 0)))
  }

  private static func drainBoth(
    _ state: inout CollectorState, outputFD: Int32, errorFD: Int32, limit: Int
  ) {
    drain(
      fd: outputFD, into: &state.output, isOpen: &state.outputOpen,
      total: state.output.count + state.error.count, limit: limit, exceeded: &state.forced)
    drain(
      fd: errorFD, into: &state.error, isOpen: &state.errorOpen,
      total: state.output.count + state.error.count, limit: limit, exceeded: &state.forced)
  }

  private static func waitForReadable(
    _ state: CollectorState, outputFD: Int32, errorFD: Int32
  ) {
    var descriptors = [
      pollfd(fd: outputFD, events: state.outputOpen ? Int16(POLLIN | POLLHUP) : 0, revents: 0),
      pollfd(fd: errorFD, events: state.errorOpen ? Int16(POLLIN | POLLHUP) : 0, revents: 0)
    ]
    _ = poll(&descriptors, 2, 5)
  }

  private static func drain(
    fd: Int32, into data: inout Data, isOpen: inout Bool, total: Int, limit: Int,
    exceeded: inout ProcessTermination?
  ) {
    guard isOpen else { return }
    var currentTotal = total
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count > 0 {
        let remaining = max(0, limit - currentTotal)
        data.append(contentsOf: buffer.prefix(min(count, remaining)))
        currentTotal += count
        if count > remaining {
          if exceeded == nil { exceeded = .outputLimitExceeded }
          return
        }
      } else if count == 0 {
        isOpen = false
        return
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      } else if errno != EINTR {
        isOpen = false
        return
      }
    }
  }

  private static func exitCode(from status: Int32) -> Int32 {
    status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
  }

  private static func failed() -> ProcessResult {
    empty(.launchFailed)
  }

  private static func empty(_ termination: ProcessTermination) -> ProcessResult {
    ProcessResult(standardOutput: Data(), standardError: Data(), termination: termination)
  }
}

// 外部コマンドの実行。締め切り・出力上限・取り消しと、その後始末。

import Darwin
import Foundation
import Testing
import VoxCore

@Suite("Process: 外部コマンドの実行")
struct ProcessRunnerTests {
  @MainActor
  @Test("Process drains both streams")
  func testProcessDrainsBothStreams() {
    let result = ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "dd if=/dev/zero bs=1024 count=1024 1>&2 2>/dev/null; printf done"],
      timeout: .seconds(3),
      outputLimit: 2 * 1024 * 1024)
    #expect(result.termination == .exited(0), "large stderr command exits")
    #expect(result.standardOutput == Data("done".utf8), "stdout is drained while stderr is large")
    #expect(result.standardError.count == 1024 * 1024, "all bounded stderr is retained")
  }

  @MainActor
  @Test("Process times out when signal ignored and descendant keeps pipe open")
  func testProcessTimesOutWhenSignalIgnoredAndDescendantKeepsPipeOpen() {
    let start = ContinuousClock.now
    let result = ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "trap '' TERM; (sleep 10) & while :; do sleep 1; done"],
      timeout: .milliseconds(120),
      outputLimit: 1024)
    let elapsed = start.duration(to: .now)
    #expect(result.termination == .timedOut, "hung process is classified as timed out")
    #expect(elapsed < .seconds(2), "timeout returns without waiting for inherited pipe descriptors")
  }

  @MainActor
  @Test("Exited root returns its output without waiting for a descendant pipe")
  func testExitedRootReturnsWithoutWaitingForDescendantPipe() {
    let start = ContinuousClock.now
    let result = ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "sleep 3 & printf parent-done; exit 0"],
      timeout: .seconds(1),
      outputLimit: 1024)
    #expect(result.termination == .exited(0), "the exit status of the root is reported")
    #expect(
      result.standardOutput == Data("parent-done".utf8), "output written before the exit is kept")
    #expect(
      start.duration(to: .now) < .milliseconds(100),
      "a descendant holding the pipe no longer stretches the call to the deadline")
  }

  @MainActor
  @Test("Final stdout burst is complete")
  func testFinalStdoutBurstIsComplete() {
    let expected = Data(repeating: 65, count: 128 * 1024)
    let result = ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\\0' A"],
      timeout: .seconds(2), outputLimit: 256 * 1024)
    #expect(result.termination == .exited(0), "final burst process exits")
    #expect(result.standardOutput == expected, "stdout emitted at exit is fully drained")
  }

  @MainActor
  @Test("Hundred millisecond deadline has no cleanup tail")
  func testHundredMillisecondDeadlineHasNoCleanupTail() {
    let start = ContinuousClock.now
    let result = ProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 10"],
      timeout: .milliseconds(100), outputLimit: 1024)
    #expect(result.termination == .timedOut, "100ms deadline is classified")
    #expect(
      start.duration(to: .now) < .milliseconds(500), "deadline does not add a one-second reader wait")
  }

  @MainActor
  @Test("Expired deadline does not launch another command")
  func testExpiredDeadlineDoesNotLaunchAnotherCommand() throws {
    let result = ProcessRunner.run(
      executable: "/definitely/not-an-executable", arguments: [],
      deadline: ContinuousClock.now.advanced(by: .milliseconds(-1)), outputLimit: 1024)
    #expect(result.termination == .timedOut, "expired shared deadline is classified")
  }

  @MainActor
  @Test("Already cancelled task does not launch")
  func testAlreadyCancelledTaskDoesNotLaunch() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("cancelled-launch")
    let task = Task.detached {
      try? await Task.sleep(for: .seconds(10))
      return ProcessRunner.run(
        executable: "/usr/bin/touch", arguments: [marker.path], timeout: .seconds(1), outputLimit: 10)
    }
    task.cancel()
    let result = await task.value
    #expect(result.termination == .cancelled, "pre-cancelled process is classified")
    #expect(
      !FileManager.default.fileExists(atPath: marker.path), "pre-cancelled process is never spawned")
  }

  @MainActor
  @Test("Concurrent process outputs stay independent")
  func testConcurrentProcessOutputsStayIndependent() async {
    await withTaskGroup(of: (Int, ProcessResult).self) { group in
      for value in 1...8 {
        group.addTask {
          let token = String(repeating: String(value), count: 32 * 1024)
          return (
            value,
            ProcessRunner.run(
              executable: "/bin/echo", arguments: [token], timeout: .seconds(2),
              outputLimit: 64 * 1024)
          )
        }
      }
      for await (value, result) in group {
        let expected = Data((String(repeating: String(value), count: 32 * 1024) + "\n").utf8)
        #expect(result.termination == .exited(0), "concurrent process exits")
        #expect(
          result.standardOutput == expected, "concurrent output is not held or mixed by another spawn"
        )
      }
    }
  }

  @MainActor
  @Test("Process output limit")
  func testProcessOutputLimit() {
    let result = ProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "yes x"], timeout: .seconds(3), outputLimit: 4096)
    #expect(result.termination == .outputLimitExceeded, "unbounded output is stopped at the limit")
    #expect(result.standardOutput.count <= 4096, "captured output stays within the shared limit")
  }

  @MainActor
  @Test("Process cancellation")
  func testProcessCancellation() async {
    let task = Task.detached {
      ProcessRunner.run(
        executable: "/bin/sh", arguments: ["-c", "sleep 10"], timeout: .seconds(5), outputLimit: 1024)
    }
    try? await Task.sleep(for: .milliseconds(80))
    task.cancel()
    let result = await task.value
    #expect(result.termination == .cancelled, "task cancellation stops the process")
  }
}

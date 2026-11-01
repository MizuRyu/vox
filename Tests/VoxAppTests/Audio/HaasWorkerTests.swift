import Darwin
import Foundation
import Testing
@testable import VoxApp

@Suite("Haas: worker protocol", .serialized)
struct HaasWorkerTests {
  private func fixture(mode: String) throws -> HaasAssets {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vox-haas-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let assets = HaasAssets(root: root)
    let ready = mode == "protocol" ? 3 : 4
    let reply: String
    switch mode {
    case "malformed": reply = "printf 'invalid\\n'"
    case "wrong_id": reply = "printf '{\"type\":\"end\",\"id\":\"wrong\",\"text\":\"試験\",\"stop\":\"complete\"}\\n'"
    case "error": reply = "printf '{\"type\":\"error\",\"id\":\"1\"}\\n'"
    case "eof": reply = "exit 0"
    case "hang", "startup": reply = ":"
    default:
      reply = "n=$((n+1)); printf '{\"type\":\"end\",\"id\":\"%s\",\"text\":\"試験\",\"stop\":\"complete\"}\\n' \"$n\""
    }
    let greeting = mode == "startup" ? ":" : "printf '{\"type\":\"ready\",\"protocol\":\(ready),\"version\":\"0.10.0\"}\\n'"
    let script = """
      #!/bin/sh
      echo $$ > child.pid
      \(greeting)
      n=0
      while IFS= read -r line; do
        case "$line" in
          *transcribe*) \(reply) ;;
        esac
      done
      """
    try Data(script.utf8).write(to: assets.executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: assets.executable.path)
    return assets
  }

  @Test("連続する要求を識別し、終了時に子プロセスを残さない")
  func successfulRequests() async throws {
    let assets = try fixture(mode: "ok")
    defer { try? FileManager.default.removeItem(at: assets.root) }
    let worker = HaasWorker(prepareAssets: { assets })
    try await worker.prepare()
    #expect(try await worker.transcribe(Data([0, 0])) == "試験")
    #expect(try await worker.transcribe(Data([0, 0])) == "試験")
    await worker.shutdown()
    try expectStopped(assets)
  }

  @Test("不正な応答・切断・停止はエラーにし、子プロセスを残さない",
    arguments: ["malformed", "wrong_id", "error", "eof", "hang", "protocol", "startup"])
  func badWorkers(mode: String) async throws {
    let assets = try fixture(mode: mode)
    defer { try? FileManager.default.removeItem(at: assets.root) }
    let worker = HaasWorker(
      prepareAssets: { assets }, startupTimeout: .seconds(3), requestTimeout: .milliseconds(100))
    if mode == "protocol" || mode == "startup" {
      await #expect(throws: HaasError.self) { try await worker.prepare() }
    } else {
      try await worker.prepare()
      await #expect(throws: HaasError.self) { _ = try await worker.transcribe(Data([0, 0])) }
    }
    await worker.shutdown()
    try expectStopped(assets)
  }

  @Test("待ち受け中の破棄はタイムアウトを待たず終了する")
  func cancelledRequest() async throws {
    let assets = try fixture(mode: "hang")
    defer { try? FileManager.default.removeItem(at: assets.root) }
    let worker = HaasWorker(prepareAssets: { assets })
    try await worker.prepare()
    let task = Task { try await worker.transcribe(Data([0, 0])) }
    try await Task.sleep(for: .milliseconds(20))
    let cancelledAt = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(cancelledAt.duration(to: .now) < .seconds(1))
    await worker.shutdown()
    try expectStopped(assets)
  }

  private func expectStopped(_ assets: HaasAssets) throws {
    let contents = try String(contentsOf: assets.root.appendingPathComponent("child.pid"), encoding: .utf8)
    let pid = try #require(Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(Darwin.kill(pid, 0) == -1)
  }
}

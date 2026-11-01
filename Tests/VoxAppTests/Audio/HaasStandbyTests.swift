import Foundation
import Testing
import VoxCore
@testable import VoxApp

@MainActor
@Suite("Haas: ホットスタンバイ", .serialized)
struct HaasStandbyTests {
  @Test("60秒を超える待機の前後で認識準備を測る",
    .enabled(if: ProcessInfo.processInfo.environment["VOX_HAAS_STANDBY_PROBE"] == "1"))
  func standbyTiming() async throws {
    let assets = HaasAssets.standard
    for url in [assets.executable, assets.model, assets.vadModel, assets.library] {
      try #require(FileManager.default.fileExists(atPath: url.path))
    }
    let recognizer = HaasSpeechRecognizer()
    let preparation = ContinuousClock.now
    await recognizer.prewarm()?.value
    let preparationMilliseconds = milliseconds(preparation.duration(to: .now))
    let cold = ContinuousClock.now
    _ = try await recognizer.start(onPreparation: nil)
    let coldMilliseconds = milliseconds(cold.duration(to: .now))
    try await recognizer.finish()
    let initialUsage = workerUsage()
    try await Task.sleep(for: .seconds(61))
    let idle = workerUsage()
    #expect(idle != "released")
    let next = ContinuousClock.now
    _ = try await recognizer.start(onPreparation: nil)
    let nextMilliseconds = milliseconds(next.duration(to: .now))
    try await recognizer.finish()
    await recognizer.abort()
    print("OK: standby_probe prewarm_ms=\(preparationMilliseconds) initial_ms=\(coldMilliseconds) after_61s_ms=\(nextMilliseconds) "
      + "initial_rss_kib_pcpu_cputime=\(initialUsage) idle_rss_kib_pcpu_cputime=\(idle)")
  }

  private func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }

  private func workerUsage() -> String {
    let result = ProcessRunner.run(executable: "/usr/bin/pgrep",
      arguments: ["-P", String(ProcessInfo.processInfo.processIdentifier), "-x", "speech-0.10.0"],
      timeout: .seconds(2), outputLimit: 256)
    guard result.termination == .exited(0),
      let pidText = String(data: result.standardOutput, encoding: .utf8),
      let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return "released" }
    let usage = ProcessRunner.run(executable: "/bin/ps", arguments: ["-p", String(pid), "-o", "rss=,pcpu=,time="],
      timeout: .seconds(2), outputLimit: 256)
    return (String(data: usage.standardOutput, encoding: .utf8) ?? "unknown")
      .split(whereSeparator: \.isWhitespace).joined(separator: ",")
  }
}

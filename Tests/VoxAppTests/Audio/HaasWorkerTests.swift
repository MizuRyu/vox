import AVFoundation
import Darwin
import Foundation
import Testing
@testable import VoxApp

@Suite("Haas: worker protocol", .serialized)
struct HaasWorkerTests {
  @Test("CPU用VADはGPUを初期化せず、Metalの環境設定を戻す",
    .enabled(if: ProcessInfo.processInfo.environment["VOX_VAD_LIBRARY"] != nil))
  func cpuOnlyVADStartup() throws {
    let environment = ProcessInfo.processInfo.environment
    let library = URL(fileURLWithPath: try #require(environment["VOX_VAD_LIBRARY"]))
    let model = URL(fileURLWithPath: try #require(environment["VOX_VAD_MODEL"]))
    let previous = getenv("GGML_METAL_DEVICES").map { String(cString: $0) }
    let vad = try HaasVAD(library: library, model: model)
    let handle = try #require(dlopen(library.path, RTLD_NOW | RTLD_LOCAL))
    defer { dlclose(handle) }
    let symbol = try #require(dlsym(handle, "speech_device_count"))
    let count = unsafeBitCast(symbol, to: (@convention(c) () -> Int).self)
    withExtendedLifetime(vad) { #expect(count() == 1, "CPUのVADでGPUの登録・シェーダー準備をしない") }
    #expect(getenv("GGML_METAL_DEVICES").map { String(cString: $0) } == previous)
    #expect(throws: HaasError.self) {
      _ = try HaasVAD(library: library, model: model.deletingLastPathComponent().appendingPathComponent("missing-model.gguf"))
    }
    #expect(getenv("GGML_METAL_DEVICES").map { String(cString: $0) } == previous)
  }

  @Test("用語は認識要求へ渡し、再利用したワーカーでも次の録音へ持ち越さない")
  func sessionKeywords() async throws {
    let assets = try fixture(mode: "ok")
    defer { try? FileManager.default.removeItem(at: assets.root) }
    let worker = HaasWorker(prepareAssets: { assets }, makeVAD: { _ in nil })
    try await worker.prepare(keywords: "Haas\nOrca")
    _ = try await worker.transcribe(Data([0, 0]))
    let file = assets.root.appendingPathComponent("request.json")
    let partial = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(partial["keywords"] == nil)
    _ = try await worker.transcribe(Data([0, 0]), isFinal: true)
    let first = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(first["keywords"] as? String == "Haas\nOrca")
    try await worker.prepare()
    _ = try await worker.transcribe(Data([0, 0]), isFinal: true)
    let second = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(second["keywords"] == nil)
    await worker.shutdown()
  }

  @Test(
    "実モデルのVADで無音・雑音を止め、通常音声と小声は認識へ渡す",
    .enabled(if: ProcessInfo.processInfo.environment["VOX_VAD_AUDIO_ROOT"] != nil))
  func realSpeechGate() async throws {
    let environment = ProcessInfo.processInfo.environment
    let audioRoot = URL(fileURLWithPath: try #require(environment["VOX_VAD_AUDIO_ROOT"]))
    let assets = try fixture(mode: "ok")
    defer { try? FileManager.default.removeItem(at: assets.root) }
    try FileManager.default.linkItem(
      atPath: try #require(environment["VOX_VAD_LIBRARY"]), toPath: assets.library.path)
    try FileManager.default.linkItem(
      atPath: try #require(environment["VOX_VAD_MODEL"]), toPath: assets.vadModel.path)
    let worker = HaasWorker(prepareAssets: { assets })
    try await worker.prepare(keywords: "Haas")
    let files = try FileManager.default.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)
      .filter {
        $0.pathExtension == "wav" && ($0.lastPathComponent.hasPrefix("noise-") || $0.lastPathComponent.hasPrefix("short-")
          || $0.lastPathComponent.hasSuffix("-quiet.wav")
          || ["haas", "house", "transcriber", "api", "ledger"].contains($0.deletingPathExtension().lastPathComponent))
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var silence = 0
    var speech = 0
    for (index, file) in files.enumerated() {
      let data = try pcm(file)
      var text = ""
      for end in stride(from: 3200, to: data.count, by: 3200) {
        text = try await worker.transcribe(Data(data.prefix(end)), windowStartFrame: index * 160000)
      }
      text = try await worker.transcribe(data, windowStartFrame: index * 160000, isFinal: true)
      if file.lastPathComponent.hasPrefix("noise-") {
        #expect(text.isEmpty, "雑音をASRへ渡してはいけない")
        silence += 1
      } else {
        #expect(text == "試験", "通常音声と小声を落としてはいけない")
        speech += 1
      }
    }
    #expect(silence == 28 && speech >= 10)
    await worker.shutdown()
    print("OK: vad_stream noise=\(silence) speech=\(speech)")
  }

  private func pcm(_ url: URL) throws -> Data {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    #expect(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
    return Data(bytes: try #require(buffer.int16ChannelData?[0]), count: Int(buffer.frameLength) * 2)
  }

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
          *transcribe*) printf '%s\\n' "$line" > request.json; \(reply) ;;
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
    let worker = HaasWorker(prepareAssets: { assets }, makeVAD: { _ in nil })
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
      prepareAssets: { assets }, startupTimeout: .seconds(3), requestTimeout: .milliseconds(100), makeVAD: { _ in nil })
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
    let worker = HaasWorker(prepareAssets: { assets }, makeVAD: { _ in nil })
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

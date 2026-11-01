import Darwin
import Foundation
import VoxCore

protocol HaasTranscribing: Sendable {
  func prepare(keywords: String, onProgress: @Sendable (SpeechPreparationStage) async -> Void) async throws
  func transcribe(_ pcm: Data, windowStartFrame: Int, isFinal: Bool) async throws -> String
  func shutdown() async
  func speechEndFrame() async -> Int?
  func setKeywords(_ keywords: String) async
}

extension HaasTranscribing {
  func prepare(keywords: String = "") async throws {
    try await prepare(keywords: keywords, onProgress: { _ in })
  }
}

/// 固定版 speech.cpp の JSONL。推論・パイプ I/O・モデルの検証は MainActor の外。
actor HaasWorker: HaasTranscribing {
  private let prepareAssets: @Sendable (@Sendable (SpeechPreparationStage) async -> Void) async throws -> HaasAssets
  private let startupTimeout: Duration
  private let requestTimeout: Duration
  private let makeVAD: @Sendable (HaasAssets) throws -> HaasVAD?
  private var vad: HaasVAD?
  private var previousText = ""
  private var previousAudio: Data?
  private var keywords = ""
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var received = Data()
  private var sequence = 0

  init(
    prepareAssets: @escaping @Sendable (@Sendable (SpeechPreparationStage) async -> Void) async throws -> HaasAssets = { progress in
      let assets = HaasAssets.standard
      try await assets.prepare(onProgress: progress)
      return assets
    },
    startupTimeout: Duration = .seconds(60), requestTimeout: Duration = .seconds(5),
    makeVAD: @escaping @Sendable (HaasAssets) throws -> HaasVAD? = {
      try HaasVAD(library: $0.library, model: $0.vadModel)
    }
  ) {
    self.prepareAssets = prepareAssets
    self.startupTimeout = startupTimeout
    self.requestTimeout = requestTimeout
    self.makeVAD = makeVAD
  }

  func prepare(keywords: String, onProgress: @Sendable (SpeechPreparationStage) async -> Void) async throws {
    let started = voxNowMilliseconds()
    if process?.isRunning == true {
      vad?.reset()
      previousText = ""
      previousAudio = nil
      self.keywords = keywords
      voxLog("haas_prepared reused=true total_ms=\(Int(voxNowMilliseconds() - started))")
      return
    }
    shutdown()
    self.keywords = keywords
    let assetsStarted = voxNowMilliseconds()
    let assets = try await prepareAssets(onProgress)
    let assetsReady = voxNowMilliseconds()
    await onProgress(.loadingModel)
    vad = try makeVAD(assets)
    let vadReady = voxNowMilliseconds()
    try Task.checkCancellation()
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    child.executableURL = assets.executable
    child.currentDirectoryURL = assets.root
    child.arguments = ["worker", assets.model.path, "--threads", "4"]
    child.standardInput = stdin
    child.standardOutput = stdout
    // 上流のエラーに発話が混ざっても診断ログへ出さない。
    child.standardError = FileHandle.nullDevice
    do {
      try child.run()
      try stdin.fileHandleForReading.close()
      try stdout.fileHandleForWriting.close()
      process = child
      input = stdin.fileHandleForWriting
      output = stdout.fileHandleForReading
      for handle in [input, output].compactMap({ $0 }) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
      }
      _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      let ready = try readMessage(deadline: .now.advanced(by: startupTimeout))
      guard ready.type == "ready", ready.protocolVersion == 4, ready.version == "0.10.0" else {
        throw HaasError.workerUnavailable
      }
      voxLog("haas_prepared reused=false assets_ms=\(Int(assetsReady - assetsStarted)) "
        + "vad_ms=\(Int(vadReady - assetsReady)) worker_ms=\(Int(voxNowMilliseconds() - vadReady)) "
        + "total_ms=\(Int(voxNowMilliseconds() - started))")
    } catch {
      shutdown()
      throw error
    }
  }

  func transcribe(_ pcm: Data, windowStartFrame: Int = 0, isFinal: Bool = false) throws -> String {
    guard process?.isRunning == true, !pcm.isEmpty else { throw HaasError.workerUnavailable }
    let deadline = ContinuousClock.now.advanced(by: requestTimeout)
    do {
      let hints = isFinal && !keywords.isEmpty ? keywords : nil
      guard let audio = try recognitionAudio(pcm, windowStartFrame: windowStartFrame, reuseSpeech: hints != nil)
      else { return previousText }
      sequence += 1
      let id = String(sequence)
      let chunk = Chunk(id: id, pcm: audio.base64EncodedString())
      try writeLine(JSONEncoder().encode(chunk), deadline: deadline)
      try writeLine(JSONEncoder().encode(Request(id: id, keywords: hints)), deadline: deadline)
      while true {
        let response = try readMessage(deadline: deadline)
        guard response.id == id else { throw HaasError.invalidResponse }
        if response.type == "progress" { continue }
        guard response.type == "end", response.stop == "complete", let text = response.text else {
          throw HaasError.recognitionFailed
        }
        previousText = text
        return text
      }
    } catch {
      shutdown()
      throw error
    }
  }

  private func recognitionAudio(_ pcm: Data, windowStartFrame: Int, reuseSpeech: Bool) throws -> Data? {
    guard let vad else { return pcm }
    if vad.windowStartFrame != windowStartFrame {
      try vad.begin(windowStartFrame: windowStartFrame)
      previousText = ""
      previousAudio = nil
    }
    if let speech = try vad.audioToRecognize(pcm) {
      previousAudio = speech
      return speech
    }
    // 同じ音声の確定だけは、途中結果で使わなかった用語ヒントを適用する。
    return reuseSpeech ? previousAudio : nil
  }

  func speechEndFrame() -> Int? { vad?.lastSpeechFrame }

  func setKeywords(_ keywords: String) { self.keywords = keywords }

  func shutdown() {
    try? input?.close()
    input = nil
    try? output?.close()
    output = nil
    if let process, process.isRunning {
      process.terminate()
      for _ in 0..<20 where process.isRunning { usleep(10_000) }
      if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      // waitUntilExit はキャンセル済み Task から呼ぶと、子が消えた後も RunLoop を待ち続けうる。
      // Foundation に reap を任せ、ここは上限つきで終了の観測だけを待つ。
      for _ in 0..<100 where process.isRunning { usleep(2_000) }
    }
    process = nil
    vad = nil
    previousText = ""
    previousAudio = nil
    keywords = ""
    received.removeAll(keepingCapacity: false)
  }

  private func writeLine(_ data: Data, deadline: ContinuousClock.Instant) throws {
    guard let input else { throw HaasError.workerUnavailable }
    let packet = data + Data([10])
    try packet.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        try check(deadline)
        let count = Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if errno == EAGAIN || errno == EINTR {
          usleep(1_000)
        } else {
          throw HaasError.workerUnavailable
        }
      }
    }
  }

  private func readMessage(deadline: ContinuousClock.Instant) throws -> Message {
    guard let output else { throw HaasError.workerUnavailable }
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      try check(deadline)
      if let newline = received.firstIndex(of: 10) {
        let line = Data(received[..<newline])
        received.removeSubrange(...newline)
        guard let message = try? JSONDecoder().decode(Message.self, from: line) else { throw HaasError.invalidResponse }
        return message
      }
      let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
      if count > 0 {
        received.append(contentsOf: buffer.prefix(count))
        guard received.count <= 1024 * 1024 else { throw HaasError.invalidResponse }
      } else if count == 0 {
        throw HaasError.workerUnavailable
      } else if errno == EAGAIN || errno == EINTR {
        usleep(2_000)
      } else {
        throw HaasError.workerUnavailable
      }
    }
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw HaasError.timedOut }
  }

  private struct Chunk: Encodable {
    let type = "chunk"
    let id: String
    let seq = 0
    let pcm: String
  }

  private struct Request: Encodable {
    let type = "transcribe"
    let id: String
    let sampleRate = 16000
    let keywords: String?

    enum CodingKeys: String, CodingKey {
      case type, id, keywords
      case sampleRate = "sample_rate"
    }
  }

  private struct Message: Decodable {
    let type: String
    let id: String?
    let text: String?
    let stop: String?
    let protocolVersion: Int?
    let version: String?

    enum CodingKeys: String, CodingKey {
      case type, id, text, stop, version
      case protocolVersion = "protocol"
    }
  }
}

// vox-m0-live-probe — Apple 自然モード (`.fastResults` なし) の発火周期を実マイクで観測する
// プローブ。測定リグではない。docs/tasks/T7-live-probe.md と docs/m0-apple-emission.md の
// 追記 (E4)/(E7) を参照。
//
// 構成は WWDC25-277 サンプル "SwiftTranscriptionSampleApp" を写している:
//   - `SpeechTranscriber(reportingOptions: [.volatileResults])`（`.fastResults` なし）
//   - `SpeechAnalyzer(modules:)`（options なし）、`prepareToAnalyze` を呼ばない
//   - `inputNode.installTap(onBus: 0, bufferSize: 4096, format: outputFormat(forBus: 0))`
//   - `AVAudioConverter(primeMethod: .none)` で `bestAvailableAudioFormat` に変換して yield

import AVFoundation
import Foundation
import Speech

// MARK: - 時刻とログ

private let probeStartNanoseconds = DispatchTime.now().uptimeNanoseconds

private func elapsedMilliseconds() -> Double {
  Double(DispatchTime.now().uptimeNanoseconds - probeStartNanoseconds) / 1_000_000
}

private func formatMilliseconds(_ value: Double) -> String {
  String(format: "%.1f", value)
}

/// tap コールバック（オーディオスレッド）と結果ループの両方から書くので排他する。
private final class ProbeLog: @unchecked Sendable {
  private let lock = NSLock()

  func emit(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }
}

private let probeLog = ProbeLog()

// MARK: - Sendable 越境用の箱

/// `AVAudioPCMBuffer` は Sendable ではない。tap から消費 Task へ渡すだけで、
/// 受け渡し後に tap 側は触らない。
private struct BufferBox: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
}

/// 20 秒経過と Enter のどちらか早い方で 1 度だけ再開する。
private final class StopBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Never>?

  init(_ continuation: CheckedContinuation<String, Never>) {
    self.continuation = continuation
  }

  func resume(reason: String) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: reason)
  }
}

// MARK: - 集計

private final class ResultTimeline: @unchecked Sendable {
  private let lock = NSLock()
  private var arrivalsMilliseconds: [Double] = []

  func record(atMilliseconds value: Double) -> Int {
    lock.lock()
    defer { lock.unlock() }
    arrivalsMilliseconds.append(value)
    return arrivalsMilliseconds.count
  }

  var snapshot: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return arrivalsMilliseconds
  }
}

private func medianInterval(of arrivals: [Double]) -> Double? {
  guard arrivals.count >= 2 else { return nil }
  var intervals: [Double] = []
  for index in 1..<arrivals.count {
    intervals.append(arrivals[index] - arrivals[index - 1])
  }
  intervals.sort()
  let middle = intervals.count / 2
  if intervals.count % 2 == 1 { return intervals[middle] }
  return (intervals[middle - 1] + intervals[middle]) / 2
}

// MARK: - サンプルの BufferConverter を写したもの

private final class ConverterInputState: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
  var processed = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }
}

private final class BufferConverter {
  enum Failure: Error {
    case failedToCreateConverter
    case failedToCreateConversionBuffer
    case conversionFailed(NSError?)
  }

  private var converter: AVAudioConverter?

  func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws
    -> AVAudioPCMBuffer {
    let inputFormat = buffer.format
    guard inputFormat != format else { return buffer }

    if converter == nil || converter?.outputFormat != format {
      converter = AVAudioConverter(from: inputFormat, to: format)
      // 先頭サンプルの品質を捨てて、変換によるタイムスタンプのずれを避ける（サンプルと同じ）。
      converter?.primeMethod = .none
    }
    guard let converter else { throw Failure.failedToCreateConverter }

    let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
    let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))
    guard
      let conversionBuffer = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat, frameCapacity: frameCapacity)
    else {
      throw Failure.failedToCreateConversionBuffer
    }

    var nsError: NSError?
    // 入力ブロックは `@Sendable` なので、渡すバッファと「渡し済みか」を箱に入れる。
    // ブロックは `convert(to:error:)` から同期的に呼ばれるだけで、並行実行はされない。
    let inputState = ConverterInputState(buffer: buffer)
    let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
      defer { inputState.processed = true }
      inputStatusPointer.pointee = inputState.processed ? .noDataNow : .haveData
      return inputState.processed ? nil : inputState.buffer
    }
    guard status != .error else { throw Failure.conversionFailed(nsError) }
    return conversionBuffer
  }
}

// MARK: - プローブ本体

private enum ProbeError: Error, CustomStringConvertible {
  case transcriberUnavailable
  case japaneseUnavailable
  case localeNotSupported(String)
  case noCompatibleAudioFormat
  case noAudioInputDevice

  var description: String {
    switch self {
    case .transcriberUnavailable:
      return "SpeechTranscriber がこの端末で利用できない"
    case .japaneseUnavailable:
      return "SpeechTranscriber が ja-JP を提供していない"
    case .localeNotSupported(let identifier):
      return "SpeechTranscriber が \(identifier) を supportedLocales に含まない"
    case .noCompatibleAudioFormat:
      return "SpeechAnalyzer.bestAvailableAudioFormat が nil を返した"
    case .noAudioInputDevice:
      return "オーディオ入力デバイスが見つからない（inputNode の sampleRate が 0）"
    }
  }
}

private enum LiveProbe {
  static let recordingSeconds = 20.0
  static let tapBufferSize: AVAudioFrameCount = 4096
  static let maxTextLength = 20

  @MainActor
  static func run(fastResults: Bool) async -> Int32 {
    let mode = fastResults ? "fast-results" : "natural"
    let reporting = fastResults ? "[volatileResults,fastResults]" : "[volatileResults]"
    probeLog.emit(
      "config mode=\(mode) reporting_options=\(reporting) locale=ja-JP "
        + "tap_buffer_size=\(tapBufferSize) prepare_to_analyze=false analyzer_options=none "
        + "duration_s=\(Int(recordingSeconds))")

    guard await ensureMicrophoneAccess() else { return 2 }

    do {
      try await probe(fastResults: fastResults)
      return 0
    } catch {
      probeLog.emit("error \(String(describing: error))")
      return 1
    }
  }

  // MARK: マイク権限

  static func ensureMicrophoneAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      probeLog.emit("mic_authorization status=authorized")
      return true
    case .notDetermined:
      probeLog.emit("mic_authorization status=notDetermined requesting=true")
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      if granted {
        probeLog.emit("mic_authorization status=authorized")
        return true
      }
      emitPermissionInstructions(status: "denied")
      return false
    case .denied:
      emitPermissionInstructions(status: "denied")
      return false
    case .restricted:
      emitPermissionInstructions(status: "restricted")
      return false
    @unknown default:
      emitPermissionInstructions(status: "unknown")
      return false
    }
  }

  static func emitPermissionInstructions(status: String) {
    probeLog.emit("mic_authorization status=\(status)")
    probeLog.emit("")
    probeLog.emit("マイクの使用が許可されていないため測定できません。次の手順で許可してください:")
    probeLog.emit("  1. システム設定 → プライバシーとセキュリティ → マイク を開く")
    probeLog.emit("  2. このコマンドを起動したターミナルアプリ（Terminal / iTerm2 / Ghostty など）を")
    probeLog.emit("     一覧から探してスイッチをオンにする")
    probeLog.emit("  3. ターミナルアプリを再起動してから、このコマンドをもう一度実行する")
    probeLog.emit("")
  }

  // MARK: 本体

  @MainActor
  static func probe(fastResults: Bool) async throws {
    guard SpeechTranscriber.isAvailable else { throw ProbeError.transcriberUnavailable }
    guard
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "ja_JP"))
    else {
      throw ProbeError.japaneseUnavailable
    }
    probeLog.emit("locale resolved=\(locale.identifier(.bcp47))")

    // Apple 公式サンプルと同じ引数。`.fastResults` は --fast-results のときだけ足す。
    var reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    if fastResults { reportingOptions.insert(.fastResults) }
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: reportingOptions,
      attributeOptions: [.audioTimeRange])  // Apple 公式サンプルと同じ。E7 でファイル給餌では無影響だが、忠実な再現を優先する
    let modules: [any SpeechModule] = [transcriber]

    // サンプルと同じ。options は渡さない。
    let analyzer = SpeechAnalyzer(modules: modules)

    try await ensureModel(for: transcriber, locale: locale)

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
    else {
      throw ProbeError.noCompatibleAudioFormat
    }
    probeLog.emit("analyzer_format \(describe(analyzerFormat))")

    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

    // サンプルと同じく results Task を start より先に立てる。detached にしない。
    let timeline = ResultTimeline()
    let resultTask = startResultTask(transcriber: transcriber, timeline: timeline)

    // `prepareToAnalyze` は呼ばない（サンプルと同じ）。
    try await analyzer.start(inputSequence: inputSequence)
    probeLog.emit("analyzer_started at_ms=\(formatMilliseconds(elapsedMilliseconds()))")

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else { throw ProbeError.noAudioInputDevice }
    probeLog.emit("input_format \(describe(inputFormat))")

    let (bufferStream, bufferBuilder) = AsyncStream<BufferBox>.makeStream(
      bufferingPolicy: .unbounded)

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(
      onBus: 0, bufferSize: tapBufferSize, format: inputFormat,
      block: makeTapBlock(builder: bufferBuilder))

    engine.prepare()
    try engine.start()
    probeLog.emit("engine_started at_ms=\(formatMilliseconds(elapsedMilliseconds()))")
    let readyMessage =
      "ready 日本語で喋ってください。\(Int(recordingSeconds)) 秒経過するか Enter を押すと終了します。"
    probeLog.emit(readyMessage)
    // ログは stderr に流すので、ユーザーがリダイレクトしていると見えない。合図は stdout にも出す。
    print(readyMessage)
    fflush(stdout)

    let converter = BufferConverter()
    let feedTask = Task { @MainActor in
      for await box in bufferStream {
        do {
          let converted = try converter.convertBuffer(box.buffer, to: analyzerFormat)
          inputBuilder.yield(AnalyzerInput(buffer: converted))
        } catch {
          probeLog.emit("convert_error \(String(describing: error))")
        }
      }
    }

    let reason = await waitForStop()
    probeLog.emit("stopping reason=\(reason) at_ms=\(formatMilliseconds(elapsedMilliseconds()))")

    engine.stop()
    inputNode.removeTap(onBus: 0)
    bufferBuilder.finish()
    await feedTask.value

    inputBuilder.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    probeLog.emit("finalized at_ms=\(formatMilliseconds(elapsedMilliseconds()))")
    resultTask.cancel()

    emitSummary(timeline: timeline)
  }

  @MainActor
  static func startResultTask(
    transcriber: SpeechTranscriber, timeline: ResultTimeline
  ) -> Task<Void, Never> {
    Task {
      do {
        for try await result in transcriber.results {
          let receivedAt = elapsedMilliseconds()
          let text = String(result.text.characters)
          let index = timeline.record(atMilliseconds: receivedAt)
          probeLog.emit(
            "result index=\(index) at_ms=\(formatMilliseconds(receivedAt)) "
              + "is_final=\(result.isFinal) text_length=\(text.count) "
              + "text=\"\(truncate(text))\"")
        }
      } catch {
        probeLog.emit("result_error \(String(describing: error))")
      }
    }
  }

  static func emitSummary(timeline: ResultTimeline) {
    let arrivals = timeline.snapshot
    let first = arrivals.first.map(formatMilliseconds) ?? "none"
    let median = medianInterval(of: arrivals).map(formatMilliseconds) ?? "none"
    probeLog.emit(
      "summary results=\(arrivals.count) first_result_at_ms=\(first) "
        + "median_interval_ms=\(median)")
  }

  static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let supported = await SpeechTranscriber.supportedLocales
    guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
      throw ProbeError.localeNotSupported(locale.identifier(.bcp47))
    }
    let installed = await SpeechTranscriber.installedLocales
    if installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
      probeLog.emit("model status=installed")
      return
    }
    probeLog.emit("model status=downloading")
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
    probeLog.emit("model status=installed")
  }

  /// 20 秒経過と Enter の早い方を待つ。stdin を読むスレッドはプロセス終了まで残す。
  static func waitForStop() async -> String {
    await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
      let box = StopBox(continuation)
      Thread.detachNewThread {
        // stdin が閉じている（EOF）ときは nil が即返るので、その場合は経過待ちに任せる。
        if readLine(strippingNewline: true) != nil {
          box.resume(reason: "enter")
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + recordingSeconds) {
        box.resume(reason: "timeout")
      }
    }
  }

  /// tap ブロックはオーディオスレッドから呼ばれる。`probe` は `@MainActor` なので、
  /// その場でクロージャを書くと main actor 隔離を継承して隔離チェックで trap する。
  /// nonisolated な関数の中で作ることで隔離を持たせない。
  nonisolated static func makeTapBlock(builder: AsyncStream<BufferBox>.Continuation)
    -> AVAudioNodeTapBlock {
    { buffer, _ in
      let receivedAt = elapsedMilliseconds()
      probeLog.emit(
        "tap buffer index=\(tapIndex.next()) at_ms=\(formatMilliseconds(receivedAt)) "
          + "frames=\(buffer.frameLength) rms=\(String(format: "%.5f", rms(of: buffer)))")
      builder.yield(BufferBox(buffer: buffer))
    }
  }

  // MARK: 補助

  static func truncate(_ text: String) -> String {
    let flattened = text.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\"", with: "'")
    if flattened.count <= maxTextLength { return flattened }
    return String(flattened.prefix(maxTextLength)) + "…"
  }

  static func describe(_ format: AVAudioFormat) -> String {
    "sample_rate=\(format.sampleRate) channels=\(format.channelCount) "
      + "common_format=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)"
  }

  /// 発話開始の目視判定用。tap のフォーマットは float32 非インターリーブが通常だが、
  /// int16 とインターリーブも一応扱う。
  static func rms(of buffer: AVAudioPCMBuffer) -> Double {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return 0 }
    let channels = Int(buffer.format.channelCount)
    let interleaved = buffer.format.isInterleaved
    let planes = interleaved ? 1 : channels
    let samplesPerPlane = interleaved ? frames * channels : frames

    var sum = 0.0
    var count = 0
    if let data = buffer.floatChannelData {
      for plane in 0..<planes {
        let pointer = data[plane]
        for index in 0..<samplesPerPlane {
          let value = Double(pointer[index])
          sum += value * value
        }
        count += samplesPerPlane
      }
    } else if let data = buffer.int16ChannelData {
      for plane in 0..<planes {
        let pointer = data[plane]
        for index in 0..<samplesPerPlane {
          let value = Double(pointer[index]) / 32768.0
          sum += value * value
        }
        count += samplesPerPlane
      }
    }
    guard count > 0 else { return 0 }
    return (sum / Double(count)).squareRoot()
  }
}

/// tap コールバックはオーディオスレッドから来るので連番も排他する。
private final class TapIndex: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}

private let tapIndex = TapIndex()

// MARK: - エントリポイント

let arguments = Array(CommandLine.arguments.dropFirst())
let unknown = arguments.filter { $0 != "--fast-results" }
if !unknown.isEmpty {
  probeLog.emit("usage: vox-m0-live-probe [--fast-results]")
  probeLog.emit("unknown_arguments \(unknown.joined(separator: " "))")
  exit(64)
}

let exitCode = await LiveProbe.run(fastResults: arguments.contains("--fast-results"))
exit(exitCode)

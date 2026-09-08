// 速報レーン。Sources/VoxM0LiveProbe/main.swift の動作確認済みの給餌経路をそのまま使う。
// アセット導入のゲートは Sources/VoxM0/main.swift の AppleEngine.prepare を写している。

import AVFoundation
import CoreMedia
import Foundation
import Speech
import VoxCore

extension AssetInventory.Status {
  fileprivate var speechAssetModuleStatus: SpeechAssetModuleStatus {
    switch self {
    case .unsupported: .unsupported
    case .supported: .supported
    case .downloading: .downloading
    case .installed: .installed
    @unknown default: .unknown
    }
  }
}

/// `AVAudioPCMBuffer` は Sendable ではない。tap から給餌 Task へ渡すだけで、
/// 受け渡し後に tap 側は触らない（プローブと同じ）。
struct BufferBox: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer
}

/// 発話開始の検出（`speech_onset_ms`）と HUD の波形用のレベル。
/// tap（オーディオスレッド）から書き、MainActor から読むので排他する。
final class AudioLevelTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var floorStartMilliseconds: Double?
  private var floorSum = 0.0
  private var floorCount = 0
  private var noiseFloor: Double?
  private var _onsetMilliseconds: Double?
  private var _level = 0.0

  static let floorWindowMilliseconds = 300.0
  static let onsetMultiplier = 4.0
  static let minimumFloor = 1e-4

  var onsetMilliseconds: Double? { lock.withLock { _onsetMilliseconds } }
  var level: Double { lock.withLock { _level } }

  func reset() {
    lock.withLock {
      floorStartMilliseconds = nil
      floorSum = 0
      floorCount = 0
      noiseFloor = nil
      _onsetMilliseconds = nil
      _level = 0
    }
  }

  func accept(rms: Double, atMilliseconds now: Double) {
    lock.withLock {
      _level = rms
      let start = floorStartMilliseconds ?? now
      floorStartMilliseconds = start
      if noiseFloor == nil {
        if now - start < Self.floorWindowMilliseconds {
          floorSum += rms
          floorCount += 1
          return
        }
        let mean = floorCount > 0 ? floorSum / Double(floorCount) : 0
        noiseFloor = max(mean, Self.minimumFloor)
      }
      guard let floor = noiseFloor, _onsetMilliseconds == nil else { return }
      if rms > floor * Self.onsetMultiplier {
        _onsetMilliseconds = now
      }
    }
  }
}

/// サンプルの BufferConverter（プローブからそのまま）。
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

  func convertBuffer(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws
    -> AVAudioPCMBuffer {
    // 多チャンネル入力は先に自前でモノラル化する。AVAudioConverter の既定の
    // チャンネル対応は先頭チャンネルしか使わず、「外部マイク」(48kHz/3ch) で先頭が
    // 無音だと analyzer に完全な無音が渡る (実機で peak=0.0000 を確認。T12)。
    // 波形メーターは全チャンネル平均なので「反応はするのに認識しない」矛盾になっていた。
    let buffer = format.channelCount == 1 && source.format.channelCount > 1
      ? try Self.downmixToMono(source) : source
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
    let inputState = ConverterInputState(buffer: buffer)
    let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
      defer { inputState.processed = true }
      inputStatusPointer.pointee = inputState.processed ? .noDataNow : .haveData
      return inputState.processed ? nil : inputState.buffer
    }
    guard status != .error else { throw Failure.conversionFailed(nsError) }
    return conversionBuffer
  }

  /// 全チャンネルの平均で 1ch float32 非インターリーブにする。サンプルレートは変えない。
  static func downmixToMono(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    let channels = Int(source.format.channelCount)
    let frames = Int(source.frameLength)
    guard
      let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: source.format.sampleRate,
        channels: 1, interleaved: false),
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))),
      let out = mono.floatChannelData?[0]
    else { throw Failure.failedToCreateConversionBuffer }
    mono.frameLength = AVAudioFrameCount(frames)
    guard frames > 0, channels > 0 else { return mono }
    let scale = 1 / Float(channels)
    if let data = source.floatChannelData {
      if source.format.isInterleaved {
        let p = data[0]
        for i in 0..<frames {
          var sum: Float = 0
          for c in 0..<channels { sum += p[i * channels + c] }
          out[i] = sum * scale
        }
      } else {
        for i in 0..<frames { out[i] = 0 }
        for c in 0..<channels {
          let p = data[c]
          for i in 0..<frames { out[i] += p[i] * scale }
        }
      }
    } else if let data = source.int16ChannelData {
      let planes = source.format.isInterleaved ? 1 : channels
      for i in 0..<frames {
        var sum: Float = 0
        for c in 0..<channels {
          let sample = source.format.isInterleaved ? data[0][i * channels + c] : data[min(c, planes - 1)][i]
          sum += Float(sample) / 32768
        }
        out[i] = sum * scale
      }
    } else {
      throw Failure.failedToCreateConversionBuffer
    }
    return mono
  }
}

enum SpeechLaneError: Error, CustomStringConvertible {
  case transcriberUnavailable
  case japaneseUnavailable
  case localeNotSupported(String)
  case assetsUnavailable(String)
  case assetDownloadInProgress
  case assetInstallationRequestUnavailable(String)
  case assetNotInstalled(String)
  case noCompatibleAudioFormat
  case noAudioInputDevice
  case voiceProcessingActivationFailed(String)
  case notRunning

  var description: String {
    switch self {
    case .transcriberUnavailable: "SpeechTranscriber がこの端末で利用できない"
    case .japaneseUnavailable: "SpeechTranscriber が ja-JP を提供していない"
    case .localeNotSupported(let id): "SpeechTranscriber が \(id) を supportedLocales に含まない"
    case .assetsUnavailable(let status): "SpeechTranscriber のアセットが利用できない (status=\(status))"
    case .assetDownloadInProgress: "SpeechTranscriber のアセット取得が既に進行中"
    case .assetInstallationRequestUnavailable(let status):
      "AssetInventory が導入要求を返さなかった (status=\(status))"
    case .assetNotInstalled(let status): "アセット導入後も installed にならなかった (status=\(status))"
    case .noCompatibleAudioFormat: "SpeechAnalyzer.bestAvailableAudioFormat が nil を返した"
    case .noAudioInputDevice: "オーディオ入力デバイスが見つからない（inputNode の sampleRate が 0）"
    case .voiceProcessingActivationFailed(let detail):
      "周囲の音を抑える処理を開始できませんでした。設定をオフにするか、マイクを確認してください（\(detail)）"
    case .notRunning: "録音していない状態で finalize が呼ばれた"
    }
  }
}

/// `start()` から `finalizeText()` / `abort()` までの 1 回分。SpeechLane は現在の 1 つだけを持つ。
@MainActor
private final class RecognitionRun {
  var isRunning = false
  var committed = ""
  var tentative = ""
  var resultCount = 0
  var firstResultReported = false
  var resultsFinished = false

  var analyzer: SpeechAnalyzer?
  var engine: AVAudioEngine?
  var configurationObserver: (any NSObjectProtocol)?
  var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
  var bufferBuilder: AsyncStream<BufferBox>.Continuation?
  var feedTask: Task<Void, Never>?
  var resultTask: Task<Void, Never>?

  /// analyzer へ yield 済みのフレーム数と、その形式のサンプルレート。
  /// `finalize(through:)` に渡す位置の計算に使う（`through: nil` は入力終端まで待つので使えない）。
  var fedFrameCount: Int64 = 0
  var sampleRate = 0.0

  /// 走っている締めの数。上限つきで待つのに使う（drainResults と同じ手）。
  var segmentFinalize = SegmentFinalizeState()
}

/// トグル ON のたびに `start()`、OFF で `finalizeText()`、破棄で `abort()`。
/// analyzer は毎回作り直す（M1 は簡潔さを優先。指示書「録音と速報レーン」）。
@MainActor
final class SpeechLane {
  static let tapBufferSize: AVAudioFrameCount = 4096
  /// finalize 後に結果ループが残りを処理し終えるのを待つ上限。
  static let resultDrainMilliseconds = 500
  /// M3。パレットを開くときの締めを待つ上限。超えたら待つのをやめて供給だけ止める。
  static let segmentFinalizeTimeoutMilliseconds = 1_000.0

  let levels = AudioLevelTracker()

  /// (committed, tentative)。committed は追記専用（ADR-002 のテキスト契約）。
  var onTextUpdate: (@MainActor (String, String) -> Void)?
  /// 最初の結果（volatile 含む）を受け取った時刻。
  var onFirstResult: (@MainActor (Double) -> Void)?
  /// アセット導入が必要になったとき（初回は約 24s かかる）。
  var onAssetInstallStarted: (@MainActor () -> Void)?
  /// 入力デバイスが変わって engine が止まったとき。引数は新しい既定入力の接続方式。
  var onCaptureInterrupted: (@MainActor (AudioTransport) -> Void)?

  private var run: RecognitionRun?
  private var lifecycle = RecognitionLifecycle()
  private var recognitionGeneration: RecognitionGeneration?
  private var interruption = CaptureInterruption()

  /// 戻り値は `analyzer_start_ms`（`SpeechAnalyzer.start` が返った時刻）。
  func start(voiceProcessingEnabled: Bool = false) async throws -> Double {
    let generation = lifecycle.begin()
    recognitionGeneration = generation
    let run = RecognitionRun()
    self.run = run
    levels.reset()

    guard SpeechTranscriber.isAvailable else { throw SpeechLaneError.transcriberUnavailable }
    guard
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "ja_JP"))
    else {
      throw SpeechLaneError.japaneseUnavailable
    }

    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [.audioTimeRange]
    )
    let modules: [any SpeechModule] = [transcriber]

    try await ensureAssets(for: transcriber, locale: locale, modules: modules)
    try Task.checkCancellation()

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
    else {
      throw SpeechLaneError.noCompatibleAudioFormat
    }

    run.sampleRate = analyzerFormat.sampleRate

    // プローブと同じ。options は渡さず、prepareToAnalyze も呼ばない。
    let analyzer = SpeechAnalyzer(modules: modules)
    run.analyzer = analyzer

    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
    run.inputBuilder = inputBuilder

    // results Task は start より先に立てる（プローブと同じ）。
    startResultTask(run, transcriber: transcriber, generation: generation)

    try await analyzer.start(inputSequence: inputSequence)
    let analyzerStartMilliseconds = voxNowMilliseconds()
    voxLog("analyzer_started at_ms=\(analyzerStartMilliseconds)")

    // Asset/permission awaits may finish after Quit cancelled the start task.
    try Task.checkCancellation()
    let engine = AVAudioEngine()
    run.engine = engine
    let inputNode = engine.inputNode
    if voiceProcessingEnabled { try Self.enableVoiceProcessing(on: inputNode) }
    let bufferStream = try startCapture(
      run, engine: engine, inputNode: inputNode, analyzerFormat: analyzerFormat,
      voiceProcessingEnabled: voiceProcessingEnabled)
    startFeedTask(
      run, bufferStream: bufferStream, inputBuilder: inputBuilder,
      analyzerFormat: analyzerFormat)
    observeConfigurationChange(run, engine: engine, generation: generation)

    run.isRunning = true
    return analyzerStartMilliseconds
  }

  private func startResultTask(
    _ run: RecognitionRun, transcriber: SpeechTranscriber, generation: RecognitionGeneration
  ) {
    run.resultTask = Task { @MainActor in
      do {
        for try await result in transcriber.results {
          guard self.lifecycle.accepts(generation) else { break }
          self.accept(result: result, into: run)
        }
      } catch is CancellationError {
        // 破棄（esc）でループを畳んだときに来る。異常ではない。
      } catch {
        voxLog("result_error \(String(describing: error))")
      }
      run.resultsFinished = true
    }
  }

  /// 入力の形式やチャンネル数が変わると engine は自分で止まる（AVAudioEngine.h）。
  /// 止まったことに気づけないと `isRunning` だけが残るので、録音の終わりとして上へ渡す。
  /// 通知は任意のスレッドから来る。ここでは engine に触らない。
  private func observeConfigurationChange(
    _ run: RecognitionRun, engine: AVAudioEngine, generation: RecognitionGeneration
  ) {
    run.configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self,
          self.interruption.decide(generation: generation, current: self.recognitionGeneration)
        else { return }
        self.onCaptureInterrupted?(MicrophoneDevices.defaultInputIdentity()?.transport ?? .unknown)
      }
    }
  }

  private static func enableVoiceProcessing(on inputNode: AVAudioInputNode) throws {
    do {
      // This must happen while the engine is stopped and before querying the changed I/O format.
      try inputNode.setVoiceProcessingEnabled(true)
      inputNode.isVoiceProcessingBypassed = false
      inputNode.isVoiceProcessingAGCEnabled = false
      inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
        enableAdvancedDucking: false, duckingLevel: .min)
    } catch {
      throw SpeechLaneError.voiceProcessingActivationFailed(error.localizedDescription)
    }
  }

  /// 入力ノードの形式を確かめて tap を張り、engine を起動する。戻り値は tap が流す音声。
  private func startCapture(
    _ run: RecognitionRun,
    engine: AVAudioEngine, inputNode: AVAudioInputNode, analyzerFormat: AVAudioFormat,
    voiceProcessingEnabled: Bool
  ) throws -> AsyncStream<BufferBox> {
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else { throw SpeechLaneError.noAudioInputDevice }
    // 診断 (T12)。どのマイクから、どの形式で拾っているか。
    let inputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
    let identity = MicrophoneDevices.defaultInputIdentity()
    voxLog(
      "audio_input device=\"\(inputDeviceName)\" "
        + "transport=\(identity?.transport.logLabel ?? "unknown") "
        + "sample_rate=\(inputFormat.sampleRate) "
        + "channels=\(inputFormat.channelCount) analyzer_rate=\(analyzerFormat.sampleRate) "
        + "voice_processing=\(voiceProcessingEnabled)")

    let (bufferStream, bufferBuilder) = AsyncStream<BufferBox>.makeStream(
      bufferingPolicy: .unbounded)
    run.bufferBuilder = bufferBuilder

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(
      onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat,
      block: Self.makeTapBlock(builder: bufferBuilder, levels: levels))

    engine.prepare()
    try engine.start()
    return bufferStream
  }

  private func startFeedTask(
    _ run: RecognitionRun,
    bufferStream: AsyncStream<BufferBox>, inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
    analyzerFormat: AVAudioFormat
  ) {
    let converter = BufferConverter()
    let debugAudio = ProcessInfo.processInfo.environment["VOX_HUD_DEBUG"] == "1"
    var debugPeak: Float = 0
    var debugFrames: Int64 = 0
    var debugLastLogMilliseconds = voxNowMilliseconds()
    var diagnosticLastMilliseconds = -Double.infinity
    var diagnosticCount = 0
    run.feedTask = Task { @MainActor in
      for await box in bufferStream {
        do {
          // Inspect each source channel before the legacy mono downmix, only on explicit request.
          // Numbers cannot identify a channel as a microphone or echo reference; retain that uncertainty.
          let diagnosticNow = voxNowMilliseconds()
          if VoxConfig.audioDiagnosticsEnabled, diagnosticCount < 16,
            diagnosticNow - diagnosticLastMilliseconds >= 1_000 {
            voxLog("audio_capture_format " + AudioCaptureDiagnostics.formatSummary(box.buffer.format))
            voxLog("audio_capture_levels " + AudioCaptureDiagnostics.channelSummary(box.buffer))
            diagnosticLastMilliseconds = diagnosticNow
            diagnosticCount += 1
          }
          let converted = try converter.convertBuffer(box.buffer, to: analyzerFormat)
          inputBuilder.yield(AnalyzerInput(buffer: converted))
          // finalize(through:) に渡す「給餌済み位置」。yield した分だけ進める。
          run.fedFrameCount += Int64(converted.frameLength)
          if debugAudio {
            // 診断 (T12)。analyzer に渡した音声の 1 秒ごとのピーク。0.01 未満が続くなら無音に近い。
            // analyzer の形式は Int16 のことがある (M0 の実測で common_format=3)。float だけ見ると
            // floatChannelData が nil で 0 のまま になり、「無音」と誤診する (T12 で実際に誤診した)。
            let frames = Int(converted.frameLength)
            if let channel = converted.floatChannelData?[0] {
              for index in 0..<frames { debugPeak = max(debugPeak, abs(channel[index])) }
            } else if let channel = converted.int16ChannelData?[0] {
              for index in 0..<frames {
                debugPeak = max(debugPeak, abs(Float(channel[index]) / 32768))
              }
            } else {
              debugPeak = -1  // 形式不明。0 と区別する
            }
            debugFrames += Int64(converted.frameLength)
            let now = voxNowMilliseconds()
            if now - debugLastLogMilliseconds >= 1_000 {
              voxLog(
                "audio_fed peak=\(String(format: "%.4f", debugPeak)) frames=\(debugFrames) "
                  + "fed_total=\(run.fedFrameCount)")
              debugPeak = 0
              debugFrames = 0
              debugLastLogMilliseconds = now
            }
          }
        } catch {
          voxLog("convert_error \(String(describing: error))")
        }
      }
    }
  }

  // MARK: M3 パレット

  /// パレットを開くときに、そこまでの tentative を final として締める。
  /// T22 で供給を止めるのをやめた（パレット表示中も喋り続けられる）ので、締めるだけになった。
  /// 締める目的は差し込む位置を固定すること。
  ///
  /// 制約は 2 つ。どちらも M0 の実測（docs/m0-results.md 追記 04:10）が根拠。
  ///   1. **給餌ループとは別のタスクから呼ぶ**。同じタスクからは自己デッドロックする（ADR-007）
  ///   2. **`through:` に給餌済みの位置を明示する**。`nil` は入力の終端まで確定する指定で、
  ///      入力が終わるまで返らない
  ///
  /// 保険として 1000ms で待つのをやめる。そのとき tentative は残したままにする
  /// （後から final が来て順序が入れ替わりうるが、ハングよりまし）。
  /// `finalize(through:)` は入力列を閉じないので、この後もそのまま給餌を続けられる。
  func finalizeSegment() async {
    guard let run, run.isRunning, let analyzer = run.analyzer else { return }
    guard
      let throughSeconds = AnalyzerFinalizePoint.throughSeconds(
        fedFrameCount: run.fedFrameCount, sampleRate: run.sampleRate)
    else {
      // 給餌がまだマージンに届いていない。締める区間が無いので呼ばない。
      voxLog("segment_finalize_skipped fed_frames=\(run.fedFrameCount) rate=\(run.sampleRate)")
      return
    }
    let through = CMTime(seconds: throughSeconds, preferredTimescale: 1_000)
    run.segmentFinalize.begin()

    // 打ち切っても取り消さない（取り消すと analyzer が途中で畳まれる）。走らせたまま先へ進む。
    Task { @MainActor in
      do {
        try await analyzer.finalize(through: through)
        voxLog(
          "segment_finalized at_ms=\(voxNowMilliseconds()) through_s=\(throughSeconds) "
            + "committed_length=\(run.committed.count)")
      } catch {
        voxLog("segment_finalize_error \(String(describing: error))")
      }
      run.segmentFinalize.complete()
    }

    await awaitSegmentFinalize(run)
    if run.segmentFinalize.hasPending {
      voxLog("segment_finalize_timeout through_s=\(throughSeconds)")
    }
  }

  /// 締めが返るのを上限つきで待つ。返らなくても取り消さない（走ったままにする）。
  private func awaitSegmentFinalize(_ run: RecognitionRun) async {
    guard run.segmentFinalize.hasPending else { return }
    await VoxPoll.wait(
      until: { !run.segmentFinalize.hasPending },
      deadline: voxNowMilliseconds() + Self.segmentFinalizeTimeoutMilliseconds,
      step: .milliseconds(5), now: voxNowMilliseconds)
  }

  /// 戻り値は `finalized_ms` と確定テキスト。
  func finalizeText() async throws -> (finalizedMilliseconds: Double, text: String) {
    guard let run, run.isRunning, let analyzer = run.analyzer else {
      throw SpeechLaneError.notRunning
    }
    guard let generation = recognitionGeneration else { throw SpeechLaneError.notRunning }
    // 締めが走ったままだと同じ analyzer に finalize が 2 つ入る。時間切れの回もここでもう一度待つ。
    await awaitSegmentFinalize(run)
    await stopFeeding(run)

    // 給餌と同じタスクから呼ぶと自己デッドロックする（ADR-007）。ここは別タスク。
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let finalizedMilliseconds = voxNowMilliseconds()

    await drainResults(run)
    let text = run.committed + run.tentative
    teardown(run)
    lifecycle.finish(generation)
    recognitionGeneration = nil

    return (finalizedMilliseconds, text)
  }

  /// esc による破棄。finalize せずに畳む。
  func abort() async {
    let generation = recognitionGeneration
    guard let run else { return }
    await stopFeeding(run)
    if let analyzer = run.analyzer {
      await analyzer.cancelAndFinishNow()
    }
    teardown(run)
    if let generation { lifecycle.abort(generation) }
    recognitionGeneration = nil
  }

  // MARK: 内部

  /// 締めと破棄で共通の前半。給餌を止めて入力列を閉じる。
  private func stopFeeding(_ run: RecognitionRun) async {
    run.isRunning = false
    run.engine?.stop()
    run.engine?.inputNode.removeTap(onBus: 0)
    run.engine = nil
    run.bufferBuilder?.finish()
    run.bufferBuilder = nil
    await run.feedTask?.value
    run.feedTask = nil
    run.inputBuilder?.finish()
    run.inputBuilder = nil
  }

  /// 締めと破棄で共通の後半。1 回分を捨てる。analyzer の畳み方だけが呼び出し側で違う。
  private func teardown(_ run: RecognitionRun) {
    if let observer = run.configurationObserver {
      NotificationCenter.default.removeObserver(
        observer, name: .AVAudioEngineConfigurationChange, object: nil)
      run.configurationObserver = nil
    }
    run.analyzer = nil
    run.resultTask?.cancel()
    run.resultTask = nil
    self.run = nil
  }

  /// 結果ループが finalize 後の残りを処理し終えるのを待つ。上限つきのポーリング。
  private func drainResults(_ run: RecognitionRun) async {
    await VoxPoll.wait(
      until: { run.resultsFinished },
      deadline: voxNowMilliseconds() + Double(Self.resultDrainMilliseconds),
      step: .milliseconds(5), now: voxNowMilliseconds)
  }

  private func accept(result: SpeechTranscriber.Result, into run: RecognitionRun) {
    let text = String(result.text.characters)
    if !run.firstResultReported {
      run.firstResultReported = true
      onFirstResult?(voxNowMilliseconds())
    }
    if result.isFinal {
      run.committed += text
      run.tentative = ""
    } else {
      run.tentative = text
    }
    run.resultCount += 1
    voxLog(
      "result index=\(run.resultCount) at_ms=\(voxNowMilliseconds()) is_final=\(result.isFinal) "
        + "committed_length=\(run.committed.count) tentative_length=\(run.tentative.count)")
    onTextUpdate?(run.committed, run.tentative)
  }

  private func ensureAssets(
    for transcriber: SpeechTranscriber, locale: Locale, modules: [any SpeechModule]
  ) async throws {
    let supported = await SpeechTranscriber.supportedLocales
    guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
      throw SpeechLaneError.localeNotSupported(locale.identifier(.bcp47))
    }

    let localeIdentifier = locale.identifier(.bcp47)
    let installedLocaleIdentifiers = Set(
      await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    if SpeechAssetReadiness.isReady(
      localeIdentifier: localeIdentifier,
      installedLocaleIdentifiers: installedLocaleIdentifiers,
      moduleStatus: .unknown) {
      return
    }

    let status = await AssetInventory.status(forModules: modules)
    if SpeechAssetReadiness.isReady(
      localeIdentifier: localeIdentifier,
      installedLocaleIdentifiers: installedLocaleIdentifiers,
      moduleStatus: status.speechAssetModuleStatus) {
      return
    }
    switch status {
    case .installed:
      return
    case .supported:
      onAssetInstallStarted?()
      voxLog("assets status=downloading")
      guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
      else {
        throw SpeechLaneError.assetInstallationRequestUnavailable(String(describing: status))
      }
      try await request.downloadAndInstall()
      let installedLocaleIdentifiers = Set(
        await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
      if !SpeechAssetReadiness.isReady(
        localeIdentifier: localeIdentifier,
        installedLocaleIdentifiers: installedLocaleIdentifiers,
        moduleStatus: .unknown) {
        let installedStatus = await AssetInventory.status(forModules: modules)
        guard
          SpeechAssetReadiness.isReady(
            localeIdentifier: localeIdentifier,
            installedLocaleIdentifiers: installedLocaleIdentifiers,
            moduleStatus: installedStatus.speechAssetModuleStatus)
        else {
          throw SpeechLaneError.assetNotInstalled(String(describing: installedStatus))
        }
      }
      voxLog("assets status=installed")
    case .downloading:
      throw SpeechLaneError.assetDownloadInProgress
    case .unsupported:
      throw SpeechLaneError.assetsUnavailable(String(describing: status))
    @unknown default:
      throw SpeechLaneError.assetsUnavailable(String(describing: status))
    }
  }

  /// tap ブロックはオーディオスレッドから呼ばれる。`@MainActor` の関数内で作ると
  /// 隔離を継承して隔離チェックで trap する（設計書 §4）。nonisolated な関数の中で作る。
  nonisolated static func makeTapBlock(
    builder: AsyncStream<BufferBox>.Continuation, levels: AudioLevelTracker
  ) -> AVAudioNodeTapBlock {
    { buffer, _ in
      levels.accept(rms: rms(of: buffer), atMilliseconds: voxNowMilliseconds())
      builder.yield(BufferBox(buffer: buffer))
    }
  }

  /// プローブの rms 実装をそのまま使う。float32 非インターリーブが通常だが int16 も扱う。
  nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Double {
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

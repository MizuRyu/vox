import AVFoundation
import Foundation
import VoxCore

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
    case .noAudioInputDevice: "マイクの音声形式を取得できませんでした。マイクの接続を確認してください"
    case .voiceProcessingActivationFailed(let detail):
      "周囲の音を抑える処理を開始できませんでした。設定をオフにするか、マイクを確認してください（\(detail)）"
    case .notRunning: "録音していない状態で finalize が呼ばれた"
    }
  }
}

/// `start()` から `finalizeText()` / `abort()` までの 1 回分。SpeechLane は現在の 1 つだけを持つ。
@MainActor
private final class RecognitionRun {
  let recognizer: any SpeechRecognizer
  var isRunning = false
  var committed = ""
  var tentative = ""
  var resultCount = 0
  var firstResultReported = false
  var engine: AVAudioEngine?
  var halCapture: HALInputCapture?
  var configurationObserver: (any NSObjectProtocol)?
  var bufferBuilder: AsyncStream<BufferBox>.Continuation?
  var feedTask: Task<Void, Never>?
  var fedFrameCount: Int64 = 0
  var failure: (any Error)?

  init(recognizer: any SpeechRecognizer) { self.recognizer = recognizer }
}

/// 締めを頼んだ側。診断ログの `reason=` に出す。
enum SegmentFinalizeReason: String {
  case palette
  /// ADR-020。発話の後の無音。
  case pause
}

/// トグル ON のたびに `start()`、OFF で `finalizeText()`、破棄で `abort()`。
/// Apple の analyzer は毎回作り直し、Haas はモデルを短時間再利用する。
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
  /// 認識モデルを準備するとき。初回は取得が必要になる。
  var onAssetInstallStarted: (@MainActor () -> Void)?
  /// 入力デバイスが変わって engine が止まったとき。引数は新しい既定入力の接続方式。
  var onCaptureInterrupted: (@MainActor (AudioTransport) -> Void)?

  /// ADR-026。確定した結果の音声時刻。保存する録音の JSON に入れる。次の `start()` で空にする。
  private(set) var finalTimings: [TimedText] = []
  private var run: RecognitionRun?
  private var haasRecognizer: HaasSpeechRecognizer?
  private var lifecycle = RecognitionLifecycle()
  private var recognitionGeneration: RecognitionGeneration?
  private var interruption = CaptureInterruption()

  /// ADR-020。無音で区切る前に、締める淡色があるかを見る。
  var hasTentativeText: Bool { run?.tentative.isEmpty == false }
  /// 締めが走っている間は重ねて頼まない（同じ analyzer に finalize を 2 つ入れない。ADR-007）。
  var isSegmentFinalizePending: Bool { run?.recognizer.isSegmentFinalizePending == true }

  /// 戻り値は認識の準備ができた時刻（既存の `analyzer_start_ms`）。
  func start(
    speechEngine: SpeechEngine = .haas,
    voiceProcessingEnabled: Bool = false, microphoneInput: MicrophoneInput = .automatic,
    recordingWriter: RecordingWriter? = nil
  ) async throws -> Double {
    let generation = lifecycle.begin()
    recognitionGeneration = generation
    finalTimings = []
    let recognizer: any SpeechRecognizer
    switch speechEngine {
    case .apple:
      await haasRecognizer?.abort()
      haasRecognizer = nil
      recognizer = AppleSpeechRecognizer()
    case .haas:
      let haas = haasRecognizer ?? HaasSpeechRecognizer()
      haasRecognizer = haas
      recognizer = haas
    }
    let run = RecognitionRun(recognizer: recognizer)
    self.run = run
    levels.reset()
    run.recognizer.onUpdate = { [weak self, weak run] result in
      guard let self, let run, self.lifecycle.accepts(generation) else { return }
      self.accept(result: result, into: run)
    }
    let analyzerFormat = try await run.recognizer.start(onAssetInstallStarted: onAssetInstallStarted)
    let analyzerStartMilliseconds = voxNowMilliseconds()
    voxLog("analyzer_started at_ms=\(analyzerStartMilliseconds)")

    // Asset/permission awaits may finish after Quit cancelled the start task.
    try Task.checkCancellation()
    let device = try MicrophoneDevices.resolve(microphoneInput)
    let bufferStream = voiceProcessingEnabled
      ? try startVoiceProcessingCapture(
        run, device: device, selection: microphoneInput, analyzerFormat: analyzerFormat, generation: generation)
      : try startHALCapture(
        run, device: device, selection: microphoneInput, analyzerFormat: analyzerFormat, generation: generation)
    startFeedTask(
      run, bufferStream: bufferStream, analyzerFormat: analyzerFormat, recordingWriter: recordingWriter)
    run.isRunning = true
    return analyzerStartMilliseconds
  }

  /// 通常の録音。選んだ機器だけを入力専用 AUHAL で開く（ADR-016）。戻り値は AUHAL が流す音声。
  private func startHALCapture(
    _ run: RecognitionRun, device: MicrophoneDevice, selection: MicrophoneInput,
    analyzerFormat: AVAudioFormat, generation: RecognitionGeneration
  ) throws -> AsyncStream<BufferBox> {
    let (bufferStream, bufferBuilder) = AsyncStream<BufferBox>.makeStream(bufferingPolicy: .unbounded)
    run.bufferBuilder = bufferBuilder
    let transport = device.transport
    let capture = try HALInputCapture(deviceID: device.id, builder: bufferBuilder, levels: levels) { [weak self] in
      Task { @MainActor in self?.captureInterrupted(generation: generation, transport: transport) }
    }
    run.halCapture = capture
    logAudioInput(
      device: device, selection: selection, format: capture.format, analyzerFormat: analyzerFormat,
      voiceProcessing: false)
    voxLog("audio_input_verified device_id=\(device.id) route=input_only")
    return bufferStream
  }

  /// 通話向け処理（実験的）。VoiceProcessingIO が要るので AVAudioEngine で開く。
  private func startVoiceProcessingCapture(
    _ run: RecognitionRun, device: MicrophoneDevice, selection: MicrophoneInput,
    analyzerFormat: AVAudioFormat, generation: RecognitionGeneration
  ) throws -> AsyncStream<BufferBox> {
    // engine が組み上げた後に入力機器を書き換えると構成変更が通知され録音が止まりうるため、
    // 既定入力と同じ機器なら Audio Unit に触れない（ADR-016 決定 6）。
    // 撤去条件: 通話向け処理を廃止するか、Vox が作る VoiceProcessingIO へ移したとき。`rg selectsDevice Sources` で確認。
    let selectsDevice = device.id != MicrophoneDevices.defaultInputDeviceID()
    let engine = AVAudioEngine()
    run.engine = engine
    let inputNode = engine.inputNode
    try Self.enableVoiceProcessing(on: inputNode)
    if selectsDevice {
      // 有効化で Audio Unit が置き換わるため、有効化の後に取得する。
      try AudioInputConfiguration.prepare(
        CoreAudioInputUnit(inputNode.audioUnit), deviceID: device.id, route: .voiceProcessing)
    }
    let bufferStream = try startEngineCapture(
      run, engine: engine, inputNode: inputNode, analyzerFormat: analyzerFormat,
      device: device, selection: selection, selectsDevice: selectsDevice)
    observeConfigurationChange(run, engine: engine, generation: generation, transport: device.transport)
    return bufferStream
  }

  /// 録音中断を上へ渡す。古い録音からの遅れた通知は捨てる。
  private func captureInterrupted(generation: RecognitionGeneration, transport: AudioTransport) {
    guard interruption.decide(generation: generation, current: recognitionGeneration) else { return }
    onCaptureInterrupted?(transport)
  }

  /// 入力の形式やチャンネル数が変わると engine は自分で止まる（AVAudioEngine.h）。
  /// 止まったことに気づけないと `isRunning` だけが残るので、録音の終わりとして上へ渡す。
  /// 通知は任意のスレッドから来る。ここでは engine に触らない。
  private func observeConfigurationChange(
    _ run: RecognitionRun, engine: AVAudioEngine, generation: RecognitionGeneration,
    transport: AudioTransport
  ) {
    run.configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in self?.captureInterrupted(generation: generation, transport: transport) }
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
  private func startEngineCapture(
    _ run: RecognitionRun,
    engine: AVAudioEngine, inputNode: AVAudioInputNode, analyzerFormat: AVAudioFormat,
    device: MicrophoneDevice, selection: MicrophoneInput, selectsDevice: Bool
  ) throws -> AsyncStream<BufferBox> {
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else { throw SpeechLaneError.noAudioInputDevice }
    logAudioInput(
      device: device, selection: selection, format: inputFormat, analyzerFormat: analyzerFormat,
      voiceProcessing: true)

    let (bufferStream, bufferBuilder) = AsyncStream<BufferBox>.makeStream(
      bufferingPolicy: .unbounded)
    run.bufferBuilder = bufferBuilder

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(
      onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat,
      block: Self.makeTapBlock(builder: bufferBuilder, levels: levels))

    engine.prepare()
    try validateSelection(inputNode, deviceID: device.id, selectsDevice: selectsDevice)
    try engine.start()
    guard engine.isRunning, inputNode.isVoiceProcessingEnabled else {
      throw AudioInputConfigurationError.configurationChanged
    }
    try validateSelection(inputNode, deviceID: device.id, selectsDevice: selectsDevice)
    voxLog("audio_input_verified device_id=\(device.id) route=voice_processing selects_device=\(selectsDevice)")
    return bufferStream
  }

  private func validateSelection(_ inputNode: AVAudioInputNode, deviceID: UInt32, selectsDevice: Bool) throws {
    guard selectsDevice else { return }
    try AudioInputConfiguration.validate(
      CoreAudioInputUnit(inputNode.audioUnit), deviceID: deviceID, route: .voiceProcessing)
  }

  /// 診断 (T12)。どのマイクから、どの形式で拾っているか。
  private func logAudioInput(
    device: MicrophoneDevice, selection: MicrophoneInput, format: AVAudioFormat,
    analyzerFormat: AVAudioFormat, voiceProcessing: Bool
  ) {
    voxLog(
      "audio_input device=\"\(device.name)\" selection=\(selection.logLabel) "
        + "device_id=\(device.id) transport=\(device.transport.logLabel) "
        + "sample_rate=\(format.sampleRate) "
        + "channels=\(format.channelCount) analyzer_rate=\(analyzerFormat.sampleRate) "
        + "voice_processing=\(voiceProcessing)")
  }

  private func startFeedTask(
    _ run: RecognitionRun,
    bufferStream: AsyncStream<BufferBox>,
    analyzerFormat: AVAudioFormat, recordingWriter: RecordingWriter?
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
          recordingWriter?.append(converted)
          if run.failure == nil {
            do { try run.recognizer.append(converted) } catch { run.failure = error }
          }
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

  func finalizeSegment(reason: SegmentFinalizeReason) async {
    guard let run, run.isRunning else { return }
    await run.recognizer.finalizeSegment(reason: reason)
  }

  /// 戻り値は `finalized_ms` と確定テキスト。
  func finalizeText() async throws -> (finalizedMilliseconds: Double, text: String) {
    guard let run, run.isRunning else {
      throw SpeechLaneError.notRunning
    }
    guard let generation = recognitionGeneration else { throw SpeechLaneError.notRunning }
    await stopFeeding(run)

    // 給餌と同じタスクから呼ぶと自己デッドロックする（ADR-007）。ここは別タスク。
    if let failure = run.failure { throw failure }
    try await run.recognizer.finish()
    let finalizedMilliseconds = voxNowMilliseconds()

    let text = run.committed + run.tentative
    teardown(run)
    lifecycle.finish(generation)
    recognitionGeneration = nil

    return (finalizedMilliseconds, text)
  }

  /// esc による破棄。finalize せずに畳む。
  func abort() async {
    let generation = recognitionGeneration
    guard let run else {
      await haasRecognizer?.abort()
      return
    }
    await stopFeeding(run)
    await run.recognizer.abort()
    teardown(run)
    if let generation { lifecycle.abort(generation) }
    recognitionGeneration = nil
  }

  // MARK: 内部

  /// 締めと破棄で共通の前半。取り込みを止め、届いた音声を渡し終える。
  private func stopFeeding(_ run: RecognitionRun) async {
    run.isRunning = false
    run.halCapture?.stop()
    run.halCapture = nil
    run.engine?.stop()
    run.engine?.inputNode.removeTap(onBus: 0)
    run.engine = nil
    run.bufferBuilder?.finish()
    run.bufferBuilder = nil
    await run.feedTask?.value
    run.feedTask = nil
  }

  /// 締めと破棄で共通の後半。1 回分の取り込みと通知を片付ける。
  private func teardown(_ run: RecognitionRun) {
    if let observer = run.configurationObserver {
      NotificationCenter.default.removeObserver(
        observer, name: .AVAudioEngineConfigurationChange, object: nil)
      run.configurationObserver = nil
    }
    run.recognizer.onUpdate = nil
    self.run = nil
  }

  private func accept(result: RecognitionUpdate, into run: RecognitionRun) {
    let text = result.text
    if !run.firstResultReported {
      run.firstResultReported = true
      onFirstResult?(voxNowMilliseconds())
    }
    if result.isFinal {
      run.committed += text
      run.tentative = ""
      finalTimings += result.timings
    } else {
      run.tentative = text
    }
    run.resultCount += 1
    voxLog(
      "result index=\(run.resultCount) at_ms=\(voxNowMilliseconds()) is_final=\(result.isFinal) "
        + "committed_length=\(run.committed.count) tentative_length=\(run.tentative.count)")
    onTextUpdate?(run.committed, run.tentative)
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

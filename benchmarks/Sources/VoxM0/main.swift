@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import FluidAudio
import Foundation
import M0HarnessCore
import Speech

enum VoxM0 {
  static func run() async {
    do {
      var arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.first == "benchmark" else {
        printUsage()
        Foundation.exit(arguments.first == "--help" || arguments.first == "help" ? 0 : 64)
      }
      arguments.removeFirst()
      let options = try BenchmarkOptions.parse(arguments)
      let allSamples = try CorpusManifest.load(from: options.manifestURL)
      let samples = options.limit.map { Array(allSamples.prefix($0)) } ?? allSamples
      guard !samples.isEmpty else { throw HarnessError.noSamples }

      let records: [BenchmarkRecord]
      do {
        switch options.engine {
        case .apple:
          let engine = try await AppleEngine.prepare(
            allowDownloads: options.allowDownloads,
            debug: options.debug
          )
          records = await run(samples: samples, engine: engine)
        case .nemotron:
          let engine = try await NemotronEngine.prepare(
            modelDirectory: options.modelDirectory,
            allowDownloads: options.allowDownloads
          )
          records = await run(samples: samples, engine: engine)
        case .parakeet:
          let engine = try await ParakeetEngine.prepare(
            modelDirectory: options.modelDirectory,
            allowDownloads: options.allowDownloads
          )
          records = await run(samples: samples, engine: engine)
        }
      } catch {
        records = samples.map {
          failureRecord(engine: options.engine, sample: $0, error: error)
        }
      }

      try write(records: records, to: options.outputURL)
      let failures = records.filter { $0.error != nil }.count
      print("wrote \(records.count) record(s) to \(options.outputURL.path); failures=\(failures)")
      if failures == records.count { Foundation.exit(2) }
    } catch {
      fputs("vox-m0: \(error.localizedDescription)\n", stderr)
      printUsage()
      Foundation.exit(1)
    }
  }

  private static func run<E: MeasurementEngine>(samples: [CorpusSample], engine: E) async
    -> [BenchmarkRecord] {
    var records: [BenchmarkRecord] = []
    for sample in samples {
      do {
        records.append(try await engine.measure(sample))
      } catch {
        records.append(failureRecord(engine: engine.kind, sample: sample, error: error))
      }
    }
    return records
  }

  private static func failureRecord(
    engine: BenchmarkEngine,
    sample: CorpusSample,
    error: Error
  ) -> BenchmarkRecord {
    BenchmarkRecord(
      engine: engine,
      dataset: sample.dataset,
      sampleID: sample.id,
      reference: sample.reference,
      hypothesis: "",
      firstTokenLatencyMilliseconds: nil,
      finalLatencyMilliseconds: nil,
      characterErrorRate: nil,
      idleRSSBytes: nil,
      peakRSSBytes: nil,
      firstModelLoadMilliseconds: nil,
      warmModelLoadMilliseconds: nil,
      error: String(reflecting: error)
    )
  }

  private static func write(records: [BenchmarkRecord], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder.m0
    let lines = try records.map { record -> String in
      guard let line = String(data: try encoder.encode(record), encoding: .utf8) else {
        throw HarnessError.encodingFailed
      }
      return line
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private static func printUsage() {
    print(
      """
      usage:
        vox-m0 benchmark --engine <apple|nemotron|parakeet> \\
          --manifest <samples.tsv> --output <results.jsonl> \\
          [--model-dir <path>] [--limit <n>] [--allow-downloads] [--debug]

      Input TSV columns:
        id  dataset  audio  reference  speech_start_ms  speech_end_ms

      Model downloads are disabled by default. Nemotron is fixed to ja-JP / 560 ms.
      Audio must be 16 kHz mono WAV; use scripts/prepare_m0_audio.sh.
      """
    )
  }
}

private protocol MeasurementEngine: Sendable {
  var kind: BenchmarkEngine { get }
  func measure(_ sample: CorpusSample) async throws -> BenchmarkRecord
}

private actor AppleEngine: MeasurementEngine {
  nonisolated let kind = BenchmarkEngine.apple
  private let locale: Locale
  private let firstLoadMilliseconds: Double
  private let warmLoadMilliseconds: Double
  private let idleRSSBytes: UInt64
  private let debug: Bool

  private init(
    locale: Locale,
    firstLoadMilliseconds: Double,
    warmLoadMilliseconds: Double,
    idleRSSBytes: UInt64,
    debug: Bool
  ) {
    self.locale = locale
    self.firstLoadMilliseconds = firstLoadMilliseconds
    self.warmLoadMilliseconds = warmLoadMilliseconds
    self.idleRSSBytes = idleRSSBytes
    self.debug = debug
  }

  static func prepare(allowDownloads: Bool, debug: Bool) async throws -> AppleEngine {
    guard SpeechTranscriber.isAvailable else { throw HarnessError.appleUnavailable }
    guard
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: "ja_JP")
      )
    else {
      throw HarnessError.appleJapaneseUnavailable
    }

    let assetProbe = makeTranscriber(locale: locale)
    let modules: [any SpeechModule] = [assetProbe]
    let assetStatus = await AssetInventory.status(forModules: modules)
    switch AssetInstallationPolicy.decision(for: assetStatus.snapshot) {
    case .ready:
      break
    case .install:
      guard allowDownloads else {
        throw HarnessError.modelDownloadRequired("Apple SpeechTranscriber ja-JP")
      }
      let installationRequest = try await performStage("AssetInventory.assetInstallationRequest") {
        try await AssetInventory.assetInstallationRequest(supporting: modules)
      }
      guard let request = installationRequest else {
        throw HarnessError.appleAssetInstallationRequestUnavailable(String(describing: assetStatus))
      }
      try await performStage("AssetInstallationRequest.downloadAndInstall") {
        try await request.downloadAndInstall()
      }
      let installedStatus = await AssetInventory.status(forModules: modules)
      guard installedStatus == .installed else {
        throw HarnessError.appleAssetNotInstalled(String(describing: installedStatus))
      }
    case .waitForDownload:
      throw HarnessError.appleAssetDownloadInProgress
    case .unavailable:
      throw HarnessError.appleAssetUnavailable(String(describing: assetStatus))
    }

    let first = try await prepareAnalyzer(locale: locale)
    let second = try await prepareAnalyzer(locale: locale)
    return AppleEngine(
      locale: locale,
      firstLoadMilliseconds: first,
      warmLoadMilliseconds: second,
      idleRSSBytes: currentRSSBytes(),
      debug: debug
    )
  }

  func measure(_ sample: CorpusSample) async throws -> BenchmarkRecord {
    try requireAudioFile(sample.audioURL)
    let transcriber = Self.makeTranscriber(locale: locale)
    let modules: [any SpeechModule] = [transcriber]
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
      throw HarnessError.noCompatibleAppleAudioFormat
    }
    emitDebug(debug, sampleID: sample.id, "analyzer_format \(audioFormatSummary(format))")
    let analyzer = try await makeAnalyzer(sample: sample, modules: modules, format: format)

    let state = TranscriptState()
    let timeline = MeasurementTimeline()
    let resultTask = startResultTask(
      sample: sample, transcriber: transcriber, state: state, timeline: timeline)
    let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)

    return try await withAsyncCleanup {
      try await performStage("SpeechAnalyzer.start(sample: \(sample.id))") {
        try await analyzer.start(inputSequence: pair.stream)
      }
      let start = monotonicNanoseconds()
      timeline.begin(atNanoseconds: start)
      state.begin(at: start)
      let sampler = startRSSSampler()

      return try await withAsyncCleanup {
        try await feedAudio(
          sample: sample, format: format, analyzer: analyzer,
          continuation: pair.continuation, timeline: timeline, start: start)
        try await performStage(
          "SpeechAnalyzer.finalizeAndFinishThroughEndOfInput(sample: \(sample.id))"
        ) {
          try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultTask.value
        let peakRSS = await finishRSSSampler(sampler)
        if let error = state.error { throw error }
        return makeRecord(
          kind: kind,
          sample: sample,
          run: summarize(state: state, sample: sample, start: start, peakRSS: peakRSS),
          idleRSS: idleRSSBytes,
          firstLoad: firstLoadMilliseconds,
          warmLoad: warmLoadMilliseconds
        )
      } cleanup: {
        sampler.cancel()
        _ = await sampler.value
      }
    } cleanup: {
      pair.continuation.finish()
      await analyzer.cancelAndFinishNow()
      resultTask.cancel()
      await resultTask.value
    }
  }

  private func makeAnalyzer(
    sample: CorpusSample, modules: [any SpeechModule], format: AVAudioFormat
  ) async throws -> SpeechAnalyzer {
    // 実験用トグル (docs/m0-apple-emission.md E7)。Apple 公式サンプルは options も
    // prepareToAnalyze も使わずに逐次発火している。どちらが発火条件に効くかを切り分ける。
    let env = ProcessInfo.processInfo.environment
    let analyzer =
      env["VOX_M0_NO_ANALYZER_OPTIONS"] == "1"
      ? SpeechAnalyzer(modules: modules)
      : SpeechAnalyzer(
        modules: modules,
        options: .init(priority: .userInitiated, modelRetention: .processLifetime)
      )
    if env["VOX_M0_NO_PREPARE"] != "1" {
      try await performStage("SpeechAnalyzer.prepareToAnalyze(sample: \(sample.id))") {
        try await analyzer.prepareToAnalyze(in: format)
      }
    }
    return analyzer
  }

  private func startResultTask(
    sample: CorpusSample, transcriber: SpeechTranscriber, state: TranscriptState,
    timeline: MeasurementTimeline
  ) -> Task<Void, Never> {
    let debugEnabled = debug
    return Task.detached(priority: .userInitiated) {
      var resultCount = 0
      defer {
        if Task.isCancelled {
          emitDebug(
            debugEnabled,
            sampleID: sample.id,
            "result_task_cancelled=true results=\(resultCount)"
          )
        } else {
          emitDebug(
            debugEnabled,
            sampleID: sample.id,
            "result_task_completed=true results=\(resultCount)"
          )
        }
      }
      do {
        for try await result in transcriber.results {
          resultCount += 1
          let text = String(result.text.characters)
          let receivedNanoseconds = monotonicNanoseconds()
          let receivedAt = timeline.milliseconds(atNanoseconds: receivedNanoseconds)
          state.accept(text: text, isFinal: result.isFinal, at: receivedNanoseconds)
          emitDebug(
            debugEnabled,
            sampleID: sample.id,
            "result index=\(resultCount) received_at_ms="
              + "\(receivedAt.map { String($0) } ?? "unstarted") "
              + "is_final=\(result.isFinal) text_length=\(text.count)"
          )
        }
      } catch {
        let stageError = MeasurementStageError(
          stage: "SpeechTranscriber.results(sample: \(sample.id))", underlying: error)
        emitDebug(
          debugEnabled,
          sampleID: sample.id,
          "result_task_error=\(stageError.description)"
        )
        state.accept(error: stageError)
      }
    }
  }

  /// 音声ファイルを実時間ペーシングで analyzer に流す。
  private func feedAudio(
    sample: CorpusSample, format: AVAudioFormat, analyzer: SpeechAnalyzer,
    continuation: AsyncStream<AnalyzerInput>.Continuation, timeline: MeasurementTimeline,
    start: UInt64
  ) async throws {
    let file = try openAudioFile(sample: sample, format: format)
    let framesPerBuffer = AVAudioFrameCount(format.sampleRate / 10)
    // AVAudioFile.length は、実際にデコードできるフレーム数より数フレーム多く
    // 報告されることがある (float32 WAV で確認)。末尾でその差分を読もうとすると
    // read が nilError で失敗するため、ごく短い端数の失敗は EOF として扱う。
    // 閾値を 4ms 相当に抑えているので、本物の読み込み失敗は従来どおり throw する。
    let tailTolerance = AVAudioFrameCount(format.sampleRate / 250)
    var yieldedBufferCount = 0
    var yieldedFrameCount: UInt64 = 0
    let finalizeTask = startPeriodicFinalize(sample: sample, analyzer: analyzer, timeline: timeline)
    defer { finalizeTask?.cancel() }
    while file.framePosition < file.length {
      let remaining = AVAudioFrameCount(file.length - file.framePosition)
      let count = min(framesPerBuffer, remaining)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
        throw HarnessError.audioBufferAllocationFailed
      }
      let positionBeforeRead = file.framePosition
      do {
        try performStage(
          "AVAudioFile.read(sample: \(sample.id), frame: \(file.framePosition))"
        ) {
          try file.read(into: buffer, frameCount: count)
        }
      } catch {
        if remaining <= tailTolerance { break }
        throw error
      }
      // read は要求より少ないフレーム数を返してよい。進んでいなければ EOF。
      if buffer.frameLength == 0 || file.framePosition == positionBeforeRead { break }
      let cumulativeFrames = yieldedFrameCount + UInt64(buffer.frameLength)
      let delayNanoseconds = AudioFeedPacing.delayNanoseconds(
        originNanoseconds: start,
        cumulativeFrames: cumulativeFrames,
        sampleRate: format.sampleRate,
        nowNanoseconds: monotonicNanoseconds()
      )
      if delayNanoseconds > 0 {
        try await Task.sleep(for: .seconds(Double(delayNanoseconds) / 1_000_000_000))
      }
      continuation.yield(AnalyzerInput(buffer: buffer))
      yieldedBufferCount += 1
      yieldedFrameCount = cumulativeFrames
      let yieldedAt = timeline.milliseconds(atNanoseconds: monotonicNanoseconds())
      let audioEndMilliseconds = Double(yieldedFrameCount) / format.sampleRate * 1_000
      emitDebug(
        debug,
        sampleID: sample.id,
        "buffer index=\(yieldedBufferCount) yielded_at_ms="
          + "\(yieldedAt.map { String($0) } ?? "unstarted") "
          + "audio_end_ms=\(audioEndMilliseconds) frames=\(buffer.frameLength) "
          + "cumulative_frames=\(yieldedFrameCount)"
      )
    }
    continuation.finish()
    let inputFinishedAt = timeline.milliseconds(atNanoseconds: monotonicNanoseconds())
    emitDebug(
      debug,
      sampleID: sample.id,
      "input_finished at_ms="
        + "\(inputFinishedAt.map { String($0) } ?? "unstarted") "
        + "yielded_buffers=\(yieldedBufferCount) yielded_frames=\(yieldedFrameCount)"
    )
  }

  private func openAudioFile(sample: CorpusSample, format: AVAudioFormat) throws -> AVAudioFile {
    let file = try performStage("AVAudioFile.init(sample: \(sample.id))") {
      try AVAudioFile(
        forReading: sample.audioURL,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
      )
    }
    emitDebug(
      debug,
      sampleID: sample.id,
      "file_processing_format \(audioFormatSummary(file.processingFormat))"
    )
    guard file.processingFormat.fingerprint == format.fingerprint else {
      throw HarnessError.audioFormatMismatch(
        expected: format.description,
        actual: file.processingFormat.description
      )
    }
    return file
  }

  /// 実験用。VOX_M0_PERIODIC_FINALIZE_MS を設定すると、給餌中にその間隔で
  /// analyzer.finalize(through:) を呼ぶ。
  ///
  /// 目的: 「SpeechAnalyzer は非ライブ入力では逐次発火しない」という仮説と、
  /// 「finalize を契機に結果を出すのであって liveness は関係ない」という仮説を
  /// 切り分ける。後者が正しければファイル給餌のまま初出遅延を測れる可能性がある。
  /// 詳細は docs/m0-results.md の「追記 (03:45)」。
  ///
  /// finalize は給餌ループと同じタスクから呼ぶと自己デッドロックする (実測で確認)。
  /// 給餌側が finalize の完了を待ち、finalize 側は入力の処理進行を待つため。
  /// 別タスクから呼ぶ。給餌は実時間ペーシングなので経過時間が音声位置に一致する。
  private func startPeriodicFinalize(
    sample: CorpusSample, analyzer: SpeechAnalyzer, timeline: MeasurementTimeline
  ) -> Task<Void, Never>? {
    let debugEnabled = debug
    let periodicFinalizeMilliseconds = ProcessInfo.processInfo
      .environment["VOX_M0_PERIODIC_FINALIZE_MS"]
      .flatMap(Double.init)
    return periodicFinalizeMilliseconds.map { period in
      Task.detached(priority: .userInitiated) {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(period / 1_000))
          if Task.isCancelled { break }
          let elapsedMilliseconds =
            timeline.milliseconds(atNanoseconds: monotonicNanoseconds()) ?? 0
          // 給餌済みより手前を確定させる。まだ送っていない位置を指定しないため。
          let throughSeconds = max(0, (elapsedMilliseconds - 100) / 1_000)
          let throughTime = CMTime(seconds: throughSeconds, preferredTimescale: 1_000)
          do {
            try await analyzer.finalize(through: throughTime)
            emitDebug(
              debugEnabled,
              sampleID: sample.id,
              "periodic_finalize through_s=\(throughSeconds)"
            )
          } catch {
            emitDebug(
              debugEnabled,
              sampleID: sample.id,
              "periodic_finalize_error=\(String(reflecting: error))"
            )
            break
          }
        }
      }
    }
  }

  private func summarize(
    state: TranscriptState, sample: CorpusSample, start: UInt64, peakRSS: UInt64
  ) -> MeasuredRun {
    MeasuredRun(
      hypothesis: state.finalText,
      firstLatency: state.firstResultNanoseconds.map {
        milliseconds($0 - start) - sample.speechStartMilliseconds
      },
      finalLatency: state.lastFinalNanoseconds.map {
        milliseconds($0 - start) - sample.speechEndMilliseconds
      },
      peakRSS: peakRSS)
  }
  private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      // .fastResults は必須。これがないと analyzer は finalize か入力終了まで結果を
      // 一切出さず、初出遅延が測れない (docs/m0-apple-emission.md の E2 で確定)。
      // 比較用に VOX_M0_NO_FAST_RESULTS=1 で外せる。
      reportingOptions: ProcessInfo.processInfo.environment["VOX_M0_NO_FAST_RESULTS"] == "1"
        ? [.volatileResults]
        : [.volatileResults, .fastResults],
      // 実験 E7。Apple 公式サンプルは .audioTimeRange を付けている。
      attributeOptions: ProcessInfo.processInfo.environment["VOX_M0_AUDIO_TIME_RANGE"] == "1"
        ? [.audioTimeRange]
        : []
    )
  }

  private static func prepareAnalyzer(locale: Locale) async throws -> Double {
    let transcriber = makeTranscriber(locale: locale)
    let modules: [any SpeechModule] = [transcriber]
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
      throw HarnessError.noCompatibleAppleAudioFormat
    }
    let start = monotonicNanoseconds()
    let analyzer = SpeechAnalyzer(
      modules: modules,
      options: .init(priority: .userInitiated, modelRetention: .processLifetime)
    )
    return try await withAsyncCleanup {
      try await performStage("SpeechAnalyzer.prepareToAnalyze(preheat)") {
        try await analyzer.prepareToAnalyze(in: format)
      }
      return milliseconds(monotonicNanoseconds() - start)
    } cleanup: {
      await analyzer.cancelAndFinishNow()
    }
  }
}

private actor NemotronEngine: MeasurementEngine {
  nonisolated let kind = BenchmarkEngine.nemotron
  private let manager: StreamingNemotronMultilingualAsrManager
  private let firstLoadMilliseconds: Double
  private let warmLoadMilliseconds: Double
  private let idleRSSBytes: UInt64

  private init(
    manager: StreamingNemotronMultilingualAsrManager,
    firstLoadMilliseconds: Double,
    warmLoadMilliseconds: Double,
    idleRSSBytes: UInt64
  ) {
    self.manager = manager
    self.firstLoadMilliseconds = firstLoadMilliseconds
    self.warmLoadMilliseconds = warmLoadMilliseconds
    self.idleRSSBytes = idleRSSBytes
  }

  static func prepare(modelDirectory: URL?, allowDownloads: Bool) async throws -> NemotronEngine {
    let directory: URL
    if let modelDirectory {
      directory = modelDirectory
    } else {
      guard allowDownloads else { throw HarnessError.modelDirectoryRequired(.nemotron) }
      directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
        languageCode: "ja-JP",
        chunkMs: 560
      )
    }

    let firstManager = StreamingNemotronMultilingualAsrManager()
    let firstStart = monotonicNanoseconds()
    try await firstManager.loadModels(from: directory)
    let firstLoad = milliseconds(monotonicNanoseconds() - firstStart)
    await firstManager.cleanup()

    let manager = StreamingNemotronMultilingualAsrManager()
    let warmStart = monotonicNanoseconds()
    try await manager.loadModels(from: directory)
    let warmLoad = milliseconds(monotonicNanoseconds() - warmStart)
    await manager.setLanguage("ja-JP")

    return NemotronEngine(
      manager: manager,
      firstLoadMilliseconds: firstLoad,
      warmLoadMilliseconds: warmLoad,
      idleRSSBytes: currentRSSBytes()
    )
  }

  func measure(_ sample: CorpusSample) async throws -> BenchmarkRecord {
    try requireAudioFile(sample.audioURL)
    let samples = try AudioConverter().resampleAudioFile(sample.audioURL)
    let state = TranscriptState()
    await manager.reset()
    await manager.setLanguage("ja-JP")
    await manager.setPartialCallback { text in
      state.accept(text: text, isFinal: false, at: monotonicNanoseconds())
    }
    let start = monotonicNanoseconds()
    state.begin(at: start)
    let sampler = startRSSSampler()

    let chunkSamples = 8_960
    var offset = 0
    while offset < samples.count {
      let end = min(offset + chunkSamples, samples.count)
      let chunk = Array(samples[offset..<end])
      try await Task.sleep(for: .seconds(Double(chunk.count) / 16_000))
      _ = try await manager.process(samples: chunk)
      offset = end
    }
    let hypothesis = try await manager.finish()
    let finishTime = monotonicNanoseconds()
    let peakRSS = await finishRSSSampler(sampler)

    let firstLatency = state.firstResultNanoseconds.map {
      milliseconds($0 - start) - sample.speechStartMilliseconds
    }
    let finalLatency = milliseconds(finishTime - start) - sample.speechEndMilliseconds
    return makeRecord(
      kind: kind,
      sample: sample,
      run: .init(
        hypothesis: hypothesis, firstLatency: firstLatency, finalLatency: finalLatency,
        peakRSS: peakRSS),
      idleRSS: idleRSSBytes,
      firstLoad: firstLoadMilliseconds,
      warmLoad: warmLoadMilliseconds
    )
  }
}

private actor ParakeetEngine: MeasurementEngine {
  nonisolated let kind = BenchmarkEngine.parakeet
  private let manager: AsrManager
  private let firstLoadMilliseconds: Double
  private let warmLoadMilliseconds: Double
  private let idleRSSBytes: UInt64

  private init(
    manager: AsrManager,
    firstLoadMilliseconds: Double,
    warmLoadMilliseconds: Double,
    idleRSSBytes: UInt64
  ) {
    self.manager = manager
    self.firstLoadMilliseconds = firstLoadMilliseconds
    self.warmLoadMilliseconds = warmLoadMilliseconds
    self.idleRSSBytes = idleRSSBytes
  }

  static func prepare(modelDirectory: URL?, allowDownloads: Bool) async throws -> ParakeetEngine {
    let directory = modelDirectory ?? AsrModels.defaultCacheDirectory(for: .tdtJa)
    let firstStart = monotonicNanoseconds()
    let firstModels: AsrModels
    if AsrModels.modelsExist(at: directory, version: .tdtJa) {
      firstModels = try await AsrModels.load(from: directory, version: .tdtJa)
    } else {
      guard allowDownloads else {
        throw HarnessError.modelDownloadRequired("FluidAudio parakeet-0.6b-ja-coreml")
      }
      firstModels = try await AsrModels.downloadAndLoad(to: directory, version: .tdtJa)
    }
    let firstLoad = milliseconds(monotonicNanoseconds() - firstStart)
    _ = firstModels

    let warmStart = monotonicNanoseconds()
    let models = try await AsrModels.load(from: directory, version: .tdtJa)
    let warmLoad = milliseconds(monotonicNanoseconds() - warmStart)
    let manager = AsrManager(models: models)
    return ParakeetEngine(
      manager: manager,
      firstLoadMilliseconds: firstLoad,
      warmLoadMilliseconds: warmLoad,
      idleRSSBytes: currentRSSBytes()
    )
  }

  func measure(_ sample: CorpusSample) async throws -> BenchmarkRecord {
    try requireAudioFile(sample.audioURL)
    try await Task.sleep(for: .milliseconds(sample.speechEndMilliseconds))
    let sampler = startRSSSampler()
    let start = monotonicNanoseconds()
    var decoderState = try TdtDecoderState(decoderLayers: 2)
    let result = try await manager.transcribe(sample.audioURL, decoderState: &decoderState)
    let finalLatency = milliseconds(monotonicNanoseconds() - start)
    let peakRSS = await finishRSSSampler(sampler)
    return makeRecord(
      kind: kind,
      sample: sample,
      run: .init(
        hypothesis: result.text, firstLatency: nil, finalLatency: finalLatency,
        peakRSS: peakRSS),
      idleRSS: idleRSSBytes,
      firstLoad: firstLoadMilliseconds,
      warmLoad: warmLoadMilliseconds
    )
  }
}

await VoxM0.run()

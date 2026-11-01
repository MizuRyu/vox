import AVFoundation
import Foundation
import VoxCore

@MainActor
private final class HaasRecognitionRun {
  var audio = HaasAudioWindow()
  var acceptingAudio = true
  var commitThrough = 0
  var nextUpdateMilliseconds = voxNowMilliseconds() + 500
  var inference: Task<Void, Never>?
  var failure: (any Error)?
  var previewEndFrame = 0
  var previewText = ""
  var requestedReason: SegmentFinalizeReason?
}

@MainActor
final class HaasSpeechRecognizer: SpeechRecognizer {
  var onUpdate: ((RecognitionUpdate) -> Void)?
  var keywords = ""
  var vocabularyTask: Task<String, Never>?
  private(set) var pauseCommitCount = 0
  private let worker: any HaasTranscribing
  private var run: HaasRecognitionRun?
  private var standbyTask: Task<Void, Never>?
  private var standbyStage: SpeechPreparationStage?
  private var standbyProgress: (@MainActor (SpeechPreparationStage) -> Void)?
  var isSegmentFinalizePending: Bool {
    guard let run else { return false }
    return run.commitThrough > run.audio.startFrame
  }

  init(worker: any HaasTranscribing = HaasWorker()) { self.worker = worker }

  @discardableResult
  func prewarm() -> Task<Void, Never>? {
    guard run == nil else { return nil }
    if let standbyTask { return standbyTask }
    standbyStage = .checkingFiles
    standbyTask = Task { [weak self, worker] in
      defer { self?.standbyStage = nil }
      do {
        try await worker.prepare(keywords: "", cachedOnly: true) { [weak self] stage in
          await self?.reportStandbyProgress(stage)
        }
      } catch is CancellationError {
        return
      } catch {
        voxLog("haas_standby ready=false")
      }
    }
    return standbyTask
  }

  private func reportStandbyProgress(_ stage: SpeechPreparationStage) {
    standbyStage = stage
    standbyProgress?(stage)
  }

  private func awaitStandby(onPreparation: (@MainActor (SpeechPreparationStage) -> Void)?) async throws {
    let pending = standbyTask
    standbyProgress = onPreparation
    if let standbyStage { onPreparation?(standbyStage) }
    await withTaskCancellationHandler {
      await pending?.value
    } onCancel: { pending?.cancel() }
    standbyTask = nil
    standbyProgress = nil
    try Task.checkCancellation()
  }

  func start(onPreparation: (@MainActor (SpeechPreparationStage) -> Void)?) async throws -> AVAudioFormat {
    pauseCommitCount = 0
    let vocabulary = vocabularyTask
    vocabularyTask = nil
    try await withTaskCancellationHandler {
      async let prepared: Void = prepareForRecording(onPreparation: onPreparation)
      if let vocabulary { keywords = await vocabulary.value }
      try Task.checkCancellation()
      try await prepared
      await worker.setKeywords(keywords)
    } onCancel: { vocabulary?.cancel() }
    try Task.checkCancellation()
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: Double(HaasAudioWindow.sampleRate), channels: 1, interleaved: false)
    else { throw SpeechLaneError.noCompatibleAudioFormat }
    run = HaasRecognitionRun()
    return format
  }

  private func prepareForRecording(onPreparation: (@MainActor (SpeechPreparationStage) -> Void)?) async throws {
    try await awaitStandby(onPreparation: onPreparation)
    try await worker.prepare(keywords: keywords, cachedOnly: false) { stage in
      await onPreparation?(stage)
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) throws {
    guard let run, run.acceptingAudio else { throw SpeechLaneError.notRunning }
    if let failure = run.failure { throw failure }
    guard let samples = buffer.int16ChannelData?[0] else { throw HaasError.recognitionFailed }
    // 上流停止時に録音全体をメモリへ積み続けない。通常は最大 12 秒と処理中の入力だけ。
    guard run.audio.frameCount + Int(buffer.frameLength) <= 30 * HaasAudioWindow.sampleRate else {
      run.failure = HaasError.audioBacklog
      throw HaasError.audioBacklog
    }
    run.audio.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
    schedule(run)
  }

  func finalizeSegment(reason: SegmentFinalizeReason) async {
    guard let run, run.acceptingAudio, run.failure == nil else { return }
    run.commitThrough = run.audio.endFrame
    run.requestedReason = reason
    schedule(run, force: true)
    // パレットを待たせるのは既存と同じ上限。推論は止めず、同時に 2 件送らない。
    await VoxPoll.wait(
      until: { !self.isSegmentFinalizePending || run.failure != nil },
      deadline: voxNowMilliseconds() + SpeechLane.segmentFinalizeTimeoutMilliseconds,
      step: .milliseconds(5), now: voxNowMilliseconds)
    voxLog("segment_finalized reason=\(reason.rawValue) engine=haas pending=\(isSegmentFinalizePending)")
  }

  func finish() async throws {
    guard let run else { throw SpeechLaneError.notRunning }
    run.acceptingAudio = false
    run.commitThrough = run.audio.endFrame
    schedule(run, force: true)
    await run.inference?.value
    if let failure = run.failure { throw failure }
    self.run = nil
    await worker.resetSession()
    keywords = ""
  }

  func abort() async {
    await discard()
    await worker.shutdown()
  }

  func discard() async {
    standbyTask?.cancel()
    await standbyTask?.value
    standbyTask = nil
    standbyStage = nil
    standbyProgress = nil
    let previous = run
    run = nil
    previous?.inference?.cancel()
    await previous?.inference?.value
    await worker.resetSession()
    keywords = ""
    vocabularyTask?.cancel()
    vocabularyTask = nil
  }

  private func schedule(_ run: HaasRecognitionRun, force: Bool = false) {
    guard self.run === run, run.inference == nil, run.failure == nil, run.audio.frameCount > 0 else { return }
    guard force || voxNowMilliseconds() >= run.nextUpdateMilliseconds else { return }
    guard force || run.audio.endFrame > run.previewEndFrame else { return }
    run.nextUpdateMilliseconds = voxNowMilliseconds() + 500
    run.inference = Task { @MainActor in
      do {
        try await self.recognize(run)
      } catch is CancellationError {
        // 破棄された回の結果を次の録音へ渡さない。
      } catch {
        run.failure = error
        voxLog("recognition_failed engine=haas")
      }
      run.inference = nil
      if run.acceptingAudio { self.schedule(run) }
    }
  }

  private func recognize(_ run: HaasRecognitionRun) async throws {
    while self.run === run, run.audio.frameCount > 0 {
      try Task.checkCancellation()
      let requested = max(0, run.commitThrough - run.audio.startFrame)
      let capped = run.audio.frameCount >= HaasAudioWindow.maximumFrames
      var isFinal = requested > 0 || capped
      // 表示した音声を区切りの後へ戻すと、途中で打った文字との順序が逆になる。
      let minimum = run.previewEndFrame - run.audio.startFrame
      let count = capped ? min(requested > 0 ? requested : Int.max, run.audio.quietCutFrames(minimumFrames: minimum))
        : (requested > 0 ? requested : run.audio.frameCount)
      let start = run.audio.startFrame
      let end = start + count
      var text: String
      if end == run.previewEndFrame && (!isFinal || keywords.isEmpty) {
        text = run.previewText
      } else {
        text = try await worker.transcribe(run.audio.prefix(frames: count), windowStartFrame: start, isFinal: isFinal)
      }
      guard self.run === run else { return }
      let speechEnd = await worker.speechEndFrame()
      guard self.run === run else { return }
      let paused = !isFinal && speechEnd.map {
        end - $0 >= Int(PauseCommitPolicy.silenceMilliseconds * 16)
      } == true && (!text.isEmpty || !run.previewText.isEmpty)
      if paused {
        isFinal = true
        if !keywords.isEmpty {
          text = try await worker.transcribe(run.audio.prefix(frames: count), windowStartFrame: start, isFinal: true)
        }
        pauseCommitCount += 1
        voxLog("segment_finalized reason=pause engine=haas pending=false")
      }
      guard self.run === run else { return }
      if isFinal {
        let hadPreview = !run.previewText.isEmpty
        run.audio.consume(frames: count)
        run.previewEndFrame = run.audio.startFrame
        run.previewText = ""
        if !text.isEmpty || hadPreview {
          onUpdate?(RecognitionUpdate(text: text, isFinal: true, timings: [
            TimedText(
              text: text, startSeconds: Double(start) / 16000, endSeconds: Double(end) / 16000)
          ], completesSentence: paused || (requested > 0 && end >= run.commitThrough
            && (!run.acceptingAudio || run.requestedReason == .pause))))
        }
      } else {
        let changed = text != run.previewText
        run.previewEndFrame = end
        run.previewText = text
        if changed { onUpdate?(RecognitionUpdate(text: text, isFinal: false)) }
        // 締めの要求が推論中に入ったら、その要求を処理してから戻る。
        if run.commitThrough <= run.audio.startFrame { return }
      }
    }
  }
}

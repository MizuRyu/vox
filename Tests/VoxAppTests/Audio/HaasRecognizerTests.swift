import AVFoundation
import Foundation
import Testing
import VoxCore
@testable import VoxApp

private actor StubHaasWorker: HaasTranscribing {
  var requests: [Data] = []
  var finalRequests: [Bool] = []
  var stopped = false
  var currentKeywords = ""
  let fails: Bool
  let delay: Duration
  let prepareDelay: Duration
  let emptyResult: Bool
  let speechEnd: Int?

  init(
    fails: Bool = false, delay: Duration = .zero, prepareDelay: Duration = .zero, emptyResult: Bool = false,
    speechEnd: Int? = nil
  ) {
    self.fails = fails
    self.delay = delay
    self.prepareDelay = prepareDelay
    self.emptyResult = emptyResult
    self.speechEnd = speechEnd
  }

  func prepare(keywords: String) async throws {
    try await Task.sleep(for: prepareDelay)
    stopped = false
  }
  func shutdown() { stopped = true }
  func speechEndFrame() -> Int? { speechEnd }
  func setKeywords(_ keywords: String) { currentKeywords = keywords }

  func transcribe(_ pcm: Data, windowStartFrame: Int, isFinal: Bool) async throws -> String {
    requests.append(pcm)
    finalRequests.append(isFinal)
    if fails { throw HaasError.recognitionFailed }
    try await Task.sleep(for: delay)
    return emptyResult ? "" : "音声\(pcm.count / 2)"
  }
}

@Suite("Haas: 認識のライフサイクル", .serialized)
@MainActor
struct HaasRecognizerTests {
  @Test("音量床の判定を待たず、VADが示す発話後の無音で淡色を確定する")
  func speechEndpointCommitsPreview() async throws {
    let worker = StubHaasWorker(speechEnd: 8000)
    let recognizer = HaasSpeechRecognizer(worker: worker)
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try await Task.sleep(for: .milliseconds(510))
    try recognizer.append(audio(32000, format: format))
    await VoxPoll.wait(until: { updates.last?.isFinal == true }, deadline: voxNowMilliseconds() + 800,
      step: .milliseconds(5), now: voxNowMilliseconds)
    #expect(updates.last?.isFinal == true)
    #expect(updates.last?.completesSentence == true)
    #expect(recognizer.pauseCommitCount == 1)
    #expect(await worker.requests.count == 1)
    await recognizer.abort()
  }

  @Test("用語取得とモデル準備を並行し、用語を次の録音へ持ち越さない")
  func parallelVocabularyPreparation() async throws {
    let worker = StubHaasWorker(prepareDelay: .milliseconds(200))
    let recognizer = HaasSpeechRecognizer(worker: worker)
    recognizer.vocabularyTask = Task.detached {
      try? await Task.sleep(for: .milliseconds(200))
      return "Haas"
    }
    let started = ContinuousClock.now
    _ = try await recognizer.start(onAssetInstallStarted: nil)
    #expect(started.duration(to: .now) < .milliseconds(350))
    #expect(await worker.currentKeywords == "Haas")
    await recognizer.abort()
    recognizer.keywords = ""
    _ = try await recognizer.start(onAssetInstallStarted: nil)
    #expect(await worker.currentKeywords.isEmpty)
    await recognizer.abort()
  }

  @Test("準備の中止は用語取得も取り消し、取得上限まで待たない")
  func cancelVocabularyPreparation() async throws {
    let worker = StubHaasWorker(prepareDelay: .seconds(3))
    let recognizer = HaasSpeechRecognizer(worker: worker)
    let vocabulary = Task.detached {
      try? await Task.sleep(for: .seconds(3))
      return "Haas"
    }
    recognizer.vocabularyTask = vocabulary
    let preparation = Task { try await recognizer.start(onAssetInstallStarted: nil) }
    try await Task.sleep(for: .milliseconds(20))
    let cancelled = ContinuousClock.now
    preparation.cancel()
    await #expect(throws: CancellationError.self) { _ = try await preparation.value }
    #expect(cancelled.duration(to: .now) < .milliseconds(500))
    #expect(vocabulary.isCancelled)
    await recognizer.abort()
  }

  @Test("発話のない音声ではHUDへ空の確定を送らない")
  func noSpeechDoesNotUpdateHUD() async throws {
    let recognizer = HaasSpeechRecognizer(worker: StubHaasWorker(emptyResult: true))
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(16000, format: format))
    try await recognizer.finish()
    #expect(updates.isEmpty)
    await recognizer.abort()
  }

  @Test("モデル準備中もキャンセルでき、録音を開始したことにしない")
  func cancelledPreparation() async throws {
    let worker = StubHaasWorker(prepareDelay: .seconds(1))
    let recognizer = HaasSpeechRecognizer(worker: worker)
    let task = Task { try await recognizer.start(onAssetInstallStarted: nil) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    await recognizer.abort()
    #expect(await worker.stopped)
  }

  @Test("確定直後に続けて録音でき、前の文字と時刻を持ち越さない")
  func consecutiveRecordings() async throws {
    let recognizer = HaasSpeechRecognizer(worker: StubHaasWorker())
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(8000, format: format))
    try await recognizer.finish()
    _ = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(4000, format: format))
    try await recognizer.finish()
    #expect(updates.map(\.text) == ["音声8000", "音声4000"])
    #expect(updates.last?.timings.first?.startSeconds == 0)
    await recognizer.abort()
  }

  private func audio(_ frames: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = try #require(buffer.int16ChannelData?[0])
    for index in 0..<frames { samples[index] = Int16(index % 100) }
    return buffer
  }

  @Test("終了は更新周期を待たず、全音声を一度ずつ確定する")
  func finishWithoutWaitingForTick() async throws {
    let worker = StubHaasWorker()
    let recognizer = HaasSpeechRecognizer(worker: worker)
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(16000, format: format))
    let started = ContinuousClock.now
    try await recognizer.finish()
    #expect(started.duration(to: .now) < .milliseconds(200))
    #expect(updates.map(\.text) == ["音声16000"])
    #expect(updates.allSatisfy { $0.isFinal })
    #expect(await worker.requests.map(\.count) == [32000])
    #expect(updates.first?.timings.first?.endSeconds == 1)
    await recognizer.abort()
  }

  @Test("話している途中で結果を出し、同じ音声の確定では再認識しない")
  func partialThenCachedFinal() async throws {
    let worker = StubHaasWorker()
    let recognizer = HaasSpeechRecognizer(worker: worker)
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try await Task.sleep(for: .milliseconds(510))
    try recognizer.append(audio(8000, format: format))
    await VoxPoll.wait(
      until: { !updates.isEmpty }, deadline: voxNowMilliseconds() + 1000,
      step: .milliseconds(5), now: voxNowMilliseconds)
    #expect(updates.first?.isFinal == false)
    try await recognizer.finish()
    #expect(updates.map(\.isFinal) == [false, true])
    #expect(await worker.requests.count == 1)
    await recognizer.abort()
  }

  @Test("用語ヒントがある回は、同じ音声でも確定時だけ補正する")
  func keywordCorrectionAtCommit() async throws {
    let worker = StubHaasWorker()
    let recognizer = HaasSpeechRecognizer(worker: worker)
    recognizer.keywords = "Haas"
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try await Task.sleep(for: .milliseconds(510))
    try recognizer.append(audio(8000, format: format))
    await VoxPoll.wait(
      until: { !updates.isEmpty }, deadline: voxNowMilliseconds() + 1000,
      step: .milliseconds(5), now: voxNowMilliseconds)
    try await recognizer.finish()
    #expect(await worker.finalRequests == [false, true])
    #expect(updates.map(\.isFinal) == [false, true])
    await recognizer.abort()
  }

  @Test("12秒を超えた音声を欠落も重複もなく区切り、時刻は録音の先頭から数える")
  func boundedWindowsCoverAllFrames() async throws {
    let worker = StubHaasWorker()
    let recognizer = HaasSpeechRecognizer(worker: worker)
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    let input = try audio(16 * 16000, format: format)
    try recognizer.append(input)
    try await recognizer.finish()
    let requests = await worker.requests
    let expected = Data(bytes: try #require(input.int16ChannelData?[0]), count: 16 * 32000)
    #expect(requests.reduce(Data(), +) == expected)
    #expect(requests.allSatisfy { $0.count <= 12 * 32000 })
    #expect(updates.allSatisfy { $0.isFinal })
    #expect(updates.first?.timings.first?.startSeconds == 0)
    #expect(updates.first?.completesSentence == false)
    #expect(updates.last?.completesSentence == true)
    #expect(updates.last?.timings.last?.endSeconds == 16)
    #expect(updates.first?.timings.last?.endSeconds == updates.last?.timings.first?.startSeconds)
    await recognizer.abort()
  }

  @Test("区切りの推論中に届いた音声は次の区間に残す")
  func audioDuringCommitIsPreserved() async throws {
    let worker = StubHaasWorker(delay: .milliseconds(40))
    let recognizer = HaasSpeechRecognizer(worker: worker)
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(16000, format: format))
    let commit = Task { await recognizer.finalizeSegment(reason: .palette) }
    try await Task.sleep(for: .milliseconds(10))
    try recognizer.append(audio(8000, format: format))
    await commit.value
    try await recognizer.finish()
    #expect(updates.filter(\.isFinal).map(\.text) == ["音声16000", "音声8000"])
    #expect(await worker.requests.map(\.count) == [32000, 16000])
    await recognizer.abort()
  }

  @Test("破棄した回の結果を出さず、次の録音へ文字を持ち越さない")
  func abortAndRestart() async throws {
    let worker = StubHaasWorker(delay: .milliseconds(100))
    let recognizer = HaasSpeechRecognizer(worker: worker)
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(16000, format: format))
    let commit = Task { await recognizer.finalizeSegment(reason: .pause) }
    try await Task.sleep(for: .milliseconds(10))
    await recognizer.abort()
    await commit.value
    #expect(updates.isEmpty)
    _ = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(4000, format: format))
    try await recognizer.finish()
    #expect(updates.map(\.text) == ["音声4000"])
    #expect(updates.first?.timings.first?.startSeconds == 0)
    await recognizer.abort()
  }

  @Test("認識が失敗した回を成功として確定しない")
  func failureIsReported() async throws {
    let worker = StubHaasWorker(fails: true)
    let recognizer = HaasSpeechRecognizer(worker: worker)
    var updates: [RecognitionUpdate] = []
    recognizer.onUpdate = { updates.append($0) }
    let format = try await recognizer.start(onAssetInstallStarted: nil)
    try recognizer.append(audio(8000, format: format))
    await #expect(throws: HaasError.self) { try await recognizer.finish() }
    #expect(updates.isEmpty)
    await recognizer.abort()
  }
}

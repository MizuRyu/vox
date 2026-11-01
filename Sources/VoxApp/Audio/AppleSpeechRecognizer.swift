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

@MainActor
private final class AppleRecognitionRun {
  let analyzer: SpeechAnalyzer
  let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
  var isRunning = true
  var fedFrameCount: Int64 = 0
  var sampleRate: Double
  var segmentFinalize = SegmentFinalizeState()
  var resultsFinished = false
  var resultTask: Task<Void, Never>?

  init(analyzer: SpeechAnalyzer, inputBuilder: AsyncStream<AnalyzerInput>.Continuation, sampleRate: Double) {
    self.analyzer = analyzer
    self.inputBuilder = inputBuilder
    self.sampleRate = sampleRate
  }
}

@MainActor
final class AppleSpeechRecognizer: SpeechRecognizer {
  var onUpdate: ((RecognitionUpdate) -> Void)?
  private var onAssetInstallStarted: (() -> Void)?
  private var run: AppleRecognitionRun?
  var isSegmentFinalizePending: Bool { run?.segmentFinalize.hasPending == true }

  func start(onAssetInstallStarted: (() -> Void)?) async throws -> AVAudioFormat {
    self.onAssetInstallStarted = onAssetInstallStarted
    guard SpeechTranscriber.isAvailable else { throw SpeechLaneError.transcriberUnavailable }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja_JP")) else {
      throw SpeechLaneError.japaneseUnavailable
    }
    let (transcriber, analyzer) = Self.makeRecognizer(locale: locale)
    let modules: [any SpeechModule] = [transcriber]
    try await ensureAssets(for: transcriber, locale: locale, modules: modules)
    try Task.checkCancellation()
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
      throw SpeechLaneError.noCompatibleAudioFormat
    }
    let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
    let run = AppleRecognitionRun(analyzer: analyzer, inputBuilder: builder, sampleRate: format.sampleRate)
    self.run = run
    // results Task は start より先に立てる（プローブと同じ）。
    run.resultTask = Task { @MainActor in
      do {
        for try await result in transcriber.results {
          guard self.run === run else { break }
          self.onUpdate?(RecognitionUpdate(
            text: String(result.text.characters), isFinal: result.isFinal,
            timings: result.isFinal ? Self.timings(of: result.text) : []))
        }
      } catch is CancellationError {
        // 破棄（esc）でループを畳んだときに来る。異常ではない。
      } catch {
        voxLog("result_error \(String(describing: error))")
      }
      run.resultsFinished = true
    }
    try await analyzer.start(inputSequence: stream)
    return format
  }

  func append(_ buffer: AVAudioPCMBuffer) throws {
    guard let run, run.isRunning else { throw SpeechLaneError.notRunning }
    run.inputBuilder.yield(AnalyzerInput(buffer: buffer))
    run.fedFrameCount += Int64(buffer.frameLength)
  }

  static func makeRecognizer(locale: Locale) -> (SpeechTranscriber, SpeechAnalyzer) {
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [.audioTimeRange]
    )
    // プローブと同じ。options は渡さず、prepareToAnalyze も呼ばない。
    return (transcriber, SpeechAnalyzer(modules: [transcriber]))
  }

  // MARK: M3 パレット / ADR-020 無音

  /// パレットを開くとき（仕様 04）と発話の後の無音（ADR-020）で、そこまでの tentative を final として締める。
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
  func finalizeSegment(reason: SegmentFinalizeReason) async {
    guard let run, run.isRunning else { return }
    // 無音とパレットの締めが重なった回。前の締めが返ってから給餌済みの位置を取る（ADR-007 / ADR-020）。
    await awaitSegmentFinalize(run)
    guard run.isRunning, self.run === run else { return }
    guard
      let throughSeconds = AnalyzerFinalizePoint.throughSeconds(
        fedFrameCount: run.fedFrameCount, sampleRate: run.sampleRate)
    else {
      // 給餌がまだマージンに届いていない。締める区間が無いので呼ばない。
      voxLog(
        "segment_finalize_skipped reason=\(reason.rawValue) fed_frames=\(run.fedFrameCount) "
          + "rate=\(run.sampleRate)")
      return
    }
    let through = CMTime(seconds: throughSeconds, preferredTimescale: 1_000)
    run.segmentFinalize.begin()

    // 打ち切っても取り消さない（取り消すと analyzer が途中で畳まれる）。走らせたまま先へ進む。
    Task { @MainActor in
      do {
        try await run.analyzer.finalize(through: through)
        voxLog(
          "segment_finalized reason=\(reason.rawValue) at_ms=\(voxNowMilliseconds()) "
            + "through_s=\(throughSeconds) ")
      } catch {
        voxLog("segment_finalize_error reason=\(reason.rawValue) \(String(describing: error))")
      }
      run.segmentFinalize.complete()
    }

    await awaitSegmentFinalize(run)
    if run.segmentFinalize.hasPending {
      voxLog("segment_finalize_timeout reason=\(reason.rawValue) through_s=\(throughSeconds)")
    }
  }

  /// 締めが返るのを上限つきで待つ。返らなくても取り消さない（走ったままにする）。
  private func awaitSegmentFinalize(_ run: AppleRecognitionRun) async {
    guard run.segmentFinalize.hasPending else { return }
    await VoxPoll.wait(
      until: { !run.segmentFinalize.hasPending },
      deadline: voxNowMilliseconds() + SpeechLane.segmentFinalizeTimeoutMilliseconds,
      step: .milliseconds(5), now: voxNowMilliseconds)
  }

  func finish() async throws {
    guard let run, run.isRunning else { throw SpeechLaneError.notRunning }
    await awaitSegmentFinalize(run)
    run.isRunning = false
    run.inputBuilder.finish()
    // 給餌と同じタスクから呼ぶと自己デッドロックする（ADR-007）。ここは別タスク。
    try await run.analyzer.finalizeAndFinishThroughEndOfInput()
    await VoxPoll.wait(
      until: { run.resultsFinished },
      deadline: voxNowMilliseconds() + Double(SpeechLane.resultDrainMilliseconds),
      step: .milliseconds(5), now: voxNowMilliseconds)
    run.resultTask?.cancel()
    self.run = nil
  }

  func abort() async {
    guard let run else { return }
    self.run = nil
    run.isRunning = false
    run.inputBuilder.finish()
    await run.analyzer.cancelAndFinishNow()
    run.resultTask?.cancel()
  }

  /// 語ごとの区間（秒）。時刻は analyzer の時間軸で、保存する wav の先頭が 0。
  private static func timings(of text: AttributedString) -> [TimedText] {
    text.runs.map { run in
      let range = run.audioTimeRange
      return TimedText(
        text: String(text[run.range].characters),
        startSeconds: range.map { $0.start.seconds }, endSeconds: range.map { $0.end.seconds })
    }
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
}

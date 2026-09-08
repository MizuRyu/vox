import Foundation
import M0HarnessCore

@main
struct M0HarnessCoreTests {
  static func main() async throws {
    try manifestParsesRequiredColumns()
    try manifestRejectsEndBeforeStart()
    try japaneseCERUsesCharactersAndIgnoresWhitespace()
    try japaneseCERIgnoresSentencePunctuation()
    try latencyClassificationUsesBindingThresholds()
    try benchmarkRecordEncodesStableSnakeCaseKeys()
    try benchmarkOptionsRequireExplicitEngineAndPaths()
    try benchmarkOptionsParseDebugFlag()
    try audioFormatFingerprintIncludesEveryAnalyzerProperty()
    try measurementTimelineReportsRelativeMilliseconds()
    try audioFeedPacingUsesAbsoluteFrameDeadline()
    try measurementStageErrorNamesTheFailingAPICall()
    try speechAssetPolicyDistinguishesEveryStatus()
    try await asyncCleanupRunsAfterFailure()
    print("M0HarnessCoreTests: 14 passed")
  }

  static func manifestParsesRequiredColumns() throws {
    let manifest = """
      id\tdataset\taudio\treference\tspeech_start_ms\tspeech_end_ms
      V001\tcustom\taudio/V001.wav\tRingBuffer.swift を開いて\t120\t1840
      """

    let samples = try CorpusManifest.parse(manifest, relativeTo: URL(fileURLWithPath: "/tmp/m0"))

    try expect(samples.count == 1, "sample count")
    try expect(samples[0].id == "V001", "sample id")
    try expect(samples[0].dataset == "custom", "dataset")
    try expect(samples[0].audioURL.path == "/tmp/m0/audio/V001.wav", "audio path")
    try expect(samples[0].reference == "RingBuffer.swift を開いて", "reference")
    try expect(samples[0].speechStartMilliseconds == 120, "speech start")
    try expect(samples[0].speechEndMilliseconds == 1_840, "speech end")
  }

  static func manifestRejectsEndBeforeStart() throws {
    let manifest = """
      id\tdataset\taudio\treference\tspeech_start_ms\tspeech_end_ms
      V001\tcustom\taudio/V001.wav\tテスト\t500\t400
      """

    do {
      _ = try CorpusManifest.parse(manifest, relativeTo: URL(fileURLWithPath: "/tmp"))
      throw TestFailure(message: "invalid time range was accepted")
    } catch is CorpusManifestError {
      // Expected.
    }
  }

  static func japaneseCERUsesCharactersAndIgnoresWhitespace() throws {
    try expect(
      CharacterErrorRate.calculate(reference: "音声 入力", hypothesis: "音声入力") == 0, "CER whitespace")
    try expect(
      CharacterErrorRate.calculate(reference: "音声入力", hypothesis: "音声認識") == 0.5,
      "CER substitutions")
  }

  static func japaneseCERIgnoresSentencePunctuation() throws {
    try expect(
      CharacterErrorRate.calculate(
        reference: "えっとRingBufferを直して",
        hypothesis: "えっと、RingBufferを直して。"
      ) == 0,
      "CER sentence punctuation"
    )
    try expect(
      CharacterErrorRate.calculate(
        reference: "推測には推測と明記して",
        hypothesis: "推測には「推測」と明記して"
      ) == 0,
      "CER Japanese quotation marks"
    )
  }

  static func latencyClassificationUsesBindingThresholds() throws {
    try expect(LatencyJudgement.classify(milliseconds: 399) == .pass, "399 ms")
    try expect(LatencyJudgement.classify(milliseconds: 400) == .pass, "400 ms")
    try expect(LatencyJudgement.classify(milliseconds: 401) == .acceptable, "401 ms")
    try expect(LatencyJudgement.classify(milliseconds: 600) == .acceptable, "600 ms")
    try expect(LatencyJudgement.classify(milliseconds: 601) == .fail, "601 ms")
    try expect(LatencyJudgement.classify(milliseconds: nil) == .notMeasured, "nil latency")
  }

  static func benchmarkRecordEncodesStableSnakeCaseKeys() throws {
    let record = BenchmarkRecord(
      engine: .apple,
      dataset: "custom",
      sampleID: "V001",
      reference: "参照",
      hypothesis: "仮説",
      firstTokenLatencyMilliseconds: 321,
      finalLatencyMilliseconds: 88,
      characterErrorRate: 0.25,
      idleRSSBytes: 100,
      peakRSSBytes: 200,
      firstModelLoadMilliseconds: 1_500,
      warmModelLoadMilliseconds: 180,
      error: nil
    )

    let object =
      try JSONSerialization.jsonObject(with: JSONEncoder.m0.encode(record)) as? [String: Any]

    try expect(object?["schema_version"] as? Int == 1, "schema version")
    try expect(object?["first_token_latency_ms"] as? Double == 321, "first-token key")
    try expect(object?["peak_rss_bytes"] as? Int == 200, "RSS key")
    try expect(object?.keys.contains("error") == true, "nil error key retained")
    try expect(object?["error"] is NSNull, "nil error encoded as null")
  }

  static func benchmarkOptionsRequireExplicitEngineAndPaths() throws {
    let options = try BenchmarkOptions.parse([
      "--engine", "nemotron",
      "--manifest", "benchmarks/m0/custom.tsv",
      "--output", "benchmarks/m0/results/nemotron.jsonl",
      "--model-dir", "/tmp/nemotron",
      "--limit", "3"
    ])

    try expect(options.engine == .nemotron, "engine option")
    try expect(options.manifestURL.path.hasSuffix("benchmarks/m0/custom.tsv"), "manifest option")
    try expect(
      options.outputURL.path.hasSuffix("benchmarks/m0/results/nemotron.jsonl"), "output option")
    try expect(options.modelDirectory?.path == "/tmp/nemotron", "model directory option")
    try expect(options.limit == 3, "limit option")
    try expect(options.allowDownloads == false, "downloads default off")
    try expect(options.debug == false, "debug default off")
  }

  static func benchmarkOptionsParseDebugFlag() throws {
    let options = try BenchmarkOptions.parse([
      "--engine", "apple",
      "--manifest", "/tmp/m0.tsv",
      "--output", "/tmp/m0.jsonl",
      "--debug"
    ])

    try expect(options.debug, "debug flag")
  }

  static func audioFormatFingerprintIncludesEveryAnalyzerProperty() throws {
    let analyzer = AudioFormatFingerprint(
      sampleRate: 16_000,
      channelCount: 1,
      commonFormat: 1,
      isInterleaved: false
    )

    try expect(analyzer == analyzer, "identical formats")
    try expect(
      analyzer
        != AudioFormatFingerprint(
          sampleRate: 48_000,
          channelCount: 1,
          commonFormat: 1,
          isInterleaved: false
        ),
      "sample rate mismatch"
    )
    try expect(
      analyzer
        != AudioFormatFingerprint(
          sampleRate: 16_000,
          channelCount: 2,
          commonFormat: 1,
          isInterleaved: false
        ),
      "channel count mismatch"
    )
    try expect(
      analyzer
        != AudioFormatFingerprint(
          sampleRate: 16_000,
          channelCount: 1,
          commonFormat: 3,
          isInterleaved: false
        ),
      "common format mismatch"
    )
    try expect(
      analyzer
        != AudioFormatFingerprint(
          sampleRate: 16_000,
          channelCount: 1,
          commonFormat: 1,
          isInterleaved: true
        ),
      "interleaving mismatch"
    )
  }

  static func measurementTimelineReportsRelativeMilliseconds() throws {
    let timeline = MeasurementTimeline()

    try expect(timeline.milliseconds(atNanoseconds: 1_250_000_000) == nil, "unstarted clock")
    timeline.begin(atNanoseconds: 1_000_000_000)
    try expect(
      timeline.milliseconds(atNanoseconds: 1_250_000_000) == 250,
      "relative milliseconds"
    )
  }

  static func audioFeedPacingUsesAbsoluteFrameDeadline() throws {
    let origin: UInt64 = 1_000_000_000

    try expect(
      AudioFeedPacing.delayNanoseconds(
        originNanoseconds: origin,
        cumulativeFrames: 1_600,
        sampleRate: 16_000,
        nowNanoseconds: origin + 20_000_000
      ) == 80_000_000,
      "first deadline"
    )
    try expect(
      AudioFeedPacing.delayNanoseconds(
        originNanoseconds: origin,
        cumulativeFrames: 3_200,
        sampleRate: 16_000,
        nowNanoseconds: origin + 130_000_000
      ) == 70_000_000,
      "later deadline does not accumulate prior overhead"
    )
    try expect(
      AudioFeedPacing.delayNanoseconds(
        originNanoseconds: origin,
        cumulativeFrames: 1_600,
        sampleRate: 16_000,
        nowNanoseconds: origin + 120_000_000
      ) == 0,
      "late feed does not sleep"
    )
  }

  static func measurementStageErrorNamesTheFailingAPICall() throws {
    let underlying = CocoaError(.fileReadUnknown)
    let error = MeasurementStageError(
      stage: "SpeechAnalyzer.analyzeSequence", underlying: underlying)

    try expect(
      error.description.contains("SpeechAnalyzer.analyzeSequence failed"),
      "stage name retained")
    try expect(
      error.description.contains(String(reflecting: underlying)),
      "underlying error retained")
  }

  static func speechAssetPolicyDistinguishesEveryStatus() throws {
    try expect(AssetInstallationPolicy.decision(for: .installed) == .ready, "installed asset")
    try expect(AssetInstallationPolicy.decision(for: .supported) == .install, "supported asset")
    try expect(
      AssetInstallationPolicy.decision(for: .downloading) == .waitForDownload,
      "downloading asset")
    try expect(
      AssetInstallationPolicy.decision(for: .unsupported) == .unavailable,
      "unsupported asset")
    try expect(
      AssetInstallationPolicy.decision(for: .unknown) == .unavailable,
      "unknown future status")
  }

  static func asyncCleanupRunsAfterFailure() async throws {
    var cleanupCount = 0
    do {
      let _: Int = try await withAsyncCleanup(
        operation: { throw TestFailure(message: "operation failed") },
        cleanup: { cleanupCount += 1 })
      throw TestFailure(message: "failing operation returned")
    } catch let error as TestFailure {
      try expect(error.message == "operation failed", "original error retained")
    }
    try expect(cleanupCount == 1, "cleanup ran exactly once")
  }

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message: message) }
  }
}

struct TestFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { "test failed: \(message)" }
}

// 計測ハーネスの共有部品。エンジン実装（main.swift）から使う。

@preconcurrency import AVFoundation
import Darwin
import Foundation
import M0HarnessCore
import Speech

final class TranscriptState: @unchecked Sendable {
  private let lock = NSLock()
  private var startNanoseconds: UInt64 = 0
  private(set) var firstResultNanoseconds: UInt64?
  private(set) var lastFinalNanoseconds: UInt64?
  private var finalizedSegments: [String] = []
  private(set) var error: Error?

  var finalText: String {
    lock.withLock { finalizedSegments.joined() }
  }

  func begin(at nanoseconds: UInt64) {
    lock.withLock { startNanoseconds = nanoseconds }
  }

  func accept(text: String, isFinal: Bool, at nanoseconds: UInt64) {
    guard !text.isEmpty else { return }
    lock.withLock {
      if firstResultNanoseconds == nil { firstResultNanoseconds = nanoseconds }
      if isFinal {
        finalizedSegments.append(text)
        lastFinalNanoseconds = nanoseconds
      }
    }
  }

  func accept(error: Error) {
    lock.withLock { self.error = error }
  }
}

/// 1 サンプル分の計測結果。エンジン固有の定数（idle RSS・モデル読み込み時間）とは分けて渡す。
struct MeasuredRun {
  let hypothesis: String
  let firstLatency: Double?
  let finalLatency: Double?
  let peakRSS: UInt64
}

func makeRecord(
  kind: BenchmarkEngine,
  sample: CorpusSample,
  run: MeasuredRun,
  idleRSS: UInt64,
  firstLoad: Double,
  warmLoad: Double
) -> BenchmarkRecord {
  BenchmarkRecord(
    engine: kind,
    dataset: sample.dataset,
    sampleID: sample.id,
    reference: sample.reference,
    hypothesis: run.hypothesis,
    firstTokenLatencyMilliseconds: run.firstLatency.map { max(0, $0) },
    finalLatencyMilliseconds: run.finalLatency.map { max(0, $0) },
    characterErrorRate: CharacterErrorRate.calculate(
      reference: sample.reference, hypothesis: run.hypothesis),
    idleRSSBytes: idleRSS,
    peakRSSBytes: run.peakRSS,
    firstModelLoadMilliseconds: firstLoad,
    warmModelLoadMilliseconds: warmLoad,
    error: nil
  )
}

func requireAudioFile(_ url: URL) throws {
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw HarnessError.audioFileMissing(url.path)
  }
}

func audioFormatSummary(_ format: AVAudioFormat) -> String {
  "sample_rate=\(format.sampleRate) channel_count=\(format.channelCount) "
    + "common_format=\(String(describing: format.commonFormat)) "
    + "common_format_raw=\(format.commonFormat.rawValue) "
    + "is_interleaved=\(format.isInterleaved)"
}

extension AVAudioFormat {
  var fingerprint: AudioFormatFingerprint {
    AudioFormatFingerprint(
      sampleRate: sampleRate,
      channelCount: channelCount,
      commonFormat: commonFormat.rawValue,
      isInterleaved: isInterleaved
    )
  }
}

func emitDebug(
  _ enabled: Bool,
  sampleID: String,
  _ message: @autoclosure () -> String
) {
  guard enabled else { return }
  fputs("[vox-m0 debug] engine=apple sample=\(sampleID) \(message())\n", stderr)
}

func performStage<Value>(
  _ stage: String,
  operation: () throws -> Value
) throws -> Value {
  do {
    return try operation()
  } catch {
    throw MeasurementStageError(stage: stage, underlying: error)
  }
}

func performStage<Value>(
  _ stage: String,
  operation: () async throws -> Value
) async throws -> Value {
  do {
    return try await operation()
  } catch {
    throw MeasurementStageError(stage: stage, underlying: error)
  }
}

func monotonicNanoseconds() -> UInt64 {
  DispatchTime.now().uptimeNanoseconds
}

func milliseconds(_ nanoseconds: UInt64) -> Double {
  Double(nanoseconds) / 1_000_000
}

func currentRSSBytes() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let status = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

func startRSSSampler() -> Task<UInt64, Never> {
  Task.detached(priority: .utility) {
    var peak = currentRSSBytes()
    while !Task.isCancelled {
      peak = max(peak, currentRSSBytes())
      try? await Task.sleep(for: .milliseconds(10))
    }
    return max(peak, currentRSSBytes())
  }
}

func finishRSSSampler(_ sampler: Task<UInt64, Never>) async -> UInt64 {
  sampler.cancel()
  return await sampler.value
}

enum HarnessError: LocalizedError {
  case noSamples
  case encodingFailed
  case appleUnavailable
  case appleJapaneseUnavailable
  case appleAssetDownloadInProgress
  case appleAssetUnavailable(String)
  case appleAssetInstallationRequestUnavailable(String)
  case appleAssetNotInstalled(String)
  case noCompatibleAppleAudioFormat
  case modelDirectoryRequired(BenchmarkEngine)
  case modelDownloadRequired(String)
  case audioFileMissing(String)
  case audioFormatMismatch(expected: String, actual: String)
  case audioBufferAllocationFailed

  var errorDescription: String? {
    switch self {
    case .noSamples: return "manifest contains no samples"
    case .encodingFailed: return "failed to encode JSONL output"
    case .appleUnavailable: return "SpeechTranscriber is unavailable on this machine"
    case .appleJapaneseUnavailable:
      return "SpeechTranscriber did not return a ja-JP supported locale"
    case .appleAssetDownloadInProgress:
      return "Apple SpeechTranscriber asset download is already in progress"
    case .appleAssetUnavailable(let status):
      return "Apple SpeechTranscriber assets are unavailable with status \(status)"
    case .appleAssetInstallationRequestUnavailable(let status):
      return "AssetInventory returned no installation request while asset status was \(status)"
    case .appleAssetNotInstalled(let status):
      return "Apple SpeechTranscriber asset installation finished with status \(status)"
    case .noCompatibleAppleAudioFormat: return "SpeechAnalyzer returned no compatible audio format"
    case .modelDirectoryRequired(let engine):
      return "--model-dir or --allow-downloads is required for \(engine.rawValue)"
    case .modelDownloadRequired(let model):
      return "model download required for \(model); rerun with --allow-downloads"
    case .audioFileMissing(let path): return "audio file not found: \(path)"
    case .audioFormatMismatch(let expected, let actual):
      return "audio format mismatch; expected \(expected), got \(actual)"
    case .audioBufferAllocationFailed: return "failed to allocate an audio buffer"
    }
  }
}

extension AssetInventory.Status {
  var snapshot: AssetStatusSnapshot {
    switch self {
    case .unsupported: .unsupported
    case .supported: .supported
    case .downloading: .downloading
    case .installed: .installed
    @unknown default: .unknown
    }
  }
}

import Foundation

public enum BenchmarkEngine: String, Codable, CaseIterable, Sendable {
  case apple
  case nemotron
  case parakeet
}

public struct MeasurementStageError: LocalizedError, CustomDebugStringConvertible, Sendable {
  public let stage: String
  public let underlyingError: String

  public init<Failure: Error>(stage: String, underlying: Failure) {
    self.stage = stage
    self.underlyingError = String(reflecting: underlying)
  }

  public var errorDescription: String? { description }
  public var description: String { "\(stage) failed: \(underlyingError)" }
  public var debugDescription: String { description }
}

public enum AssetStatusSnapshot: Sendable {
  case unsupported
  case supported
  case downloading
  case installed
  case unknown
}

public enum AssetInstallationDecision: Equatable, Sendable {
  case ready
  case install
  case waitForDownload
  case unavailable
}

public enum AssetInstallationPolicy {
  public static func decision(for status: AssetStatusSnapshot) -> AssetInstallationDecision {
    switch status {
    case .installed: .ready
    case .supported: .install
    case .downloading: .waitForDownload
    case .unsupported, .unknown: .unavailable
    }
  }
}

public struct AudioFormatFingerprint: Equatable, Sendable {
  public let sampleRate: Double
  public let channelCount: UInt32
  public let commonFormat: UInt
  public let isInterleaved: Bool

  public init(
    sampleRate: Double,
    channelCount: UInt32,
    commonFormat: UInt,
    isInterleaved: Bool
  ) {
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.commonFormat = commonFormat
    self.isInterleaved = isInterleaved
  }
}

public final class MeasurementTimeline: @unchecked Sendable {
  private let lock = NSLock()
  private var originNanoseconds: UInt64?

  public init() {}

  public func begin(atNanoseconds nanoseconds: UInt64) {
    lock.withLock { originNanoseconds = nanoseconds }
  }

  public func milliseconds(atNanoseconds nanoseconds: UInt64) -> Double? {
    lock.withLock {
      guard let originNanoseconds, nanoseconds >= originNanoseconds else { return nil }
      return Double(nanoseconds - originNanoseconds) / 1_000_000
    }
  }
}

public enum AudioFeedPacing {
  public static func delayNanoseconds(
    originNanoseconds: UInt64,
    cumulativeFrames: UInt64,
    sampleRate: Double,
    nowNanoseconds: UInt64
  ) -> UInt64 {
    guard sampleRate > 0 else { return 0 }
    let audioNanoseconds = UInt64(
      (Double(cumulativeFrames) / sampleRate * 1_000_000_000).rounded())
    let (deadline, overflow) = originNanoseconds.addingReportingOverflow(audioNanoseconds)
    guard !overflow, deadline > nowNanoseconds else { return 0 }
    return deadline - nowNanoseconds
  }
}

public func withAsyncCleanup<Value>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async throws -> Value,
  cleanup: () async -> Void
) async throws -> Value {
  do {
    let value = try await operation()
    await cleanup()
    return value
  } catch {
    await cleanup()
    throw error
  }
}

public struct CorpusSample: Equatable, Sendable {
  public let id: String
  public let dataset: String
  public let audioURL: URL
  public let reference: String
  public let speechStartMilliseconds: Double
  public let speechEndMilliseconds: Double

  public init(
    id: String,
    dataset: String,
    audioURL: URL,
    reference: String,
    speechStartMilliseconds: Double,
    speechEndMilliseconds: Double
  ) {
    self.id = id
    self.dataset = dataset
    self.audioURL = audioURL
    self.reference = reference
    self.speechStartMilliseconds = speechStartMilliseconds
    self.speechEndMilliseconds = speechEndMilliseconds
  }
}

public enum CorpusManifestError: LocalizedError, Equatable {
  case missingHeader
  case invalidHeader([String])
  case invalidFieldCount(line: Int, actual: Int)
  case invalidTimestamp(line: Int)
  case invalidTimeRange(line: Int)

  public var errorDescription: String? {
    switch self {
    case .missingHeader:
      return "manifest is empty"
    case .invalidHeader(let fields):
      return "invalid manifest header: \(fields.joined(separator: ", "))"
    case .invalidFieldCount(let line, let actual):
      return "manifest line \(line) has \(actual) fields; expected 6"
    case .invalidTimestamp(let line):
      return "manifest line \(line) contains an invalid timestamp"
    case .invalidTimeRange(let line):
      return "manifest line \(line) has speech_end_ms before speech_start_ms"
    }
  }
}

public enum CorpusManifest {
  public static let header = [
    "id", "dataset", "audio", "reference", "speech_start_ms", "speech_end_ms"
  ]

  public static func load(from url: URL) throws -> [CorpusSample] {
    try parse(String(contentsOf: url, encoding: .utf8), relativeTo: url.deletingLastPathComponent())
  }

  public static func parse(_ contents: String, relativeTo baseURL: URL) throws -> [CorpusSample] {
    let lines = contents.split(whereSeparator: \Character.isNewline).map(String.init)
    guard let first = lines.first else {
      throw CorpusManifestError.missingHeader
    }

    let actualHeader = split(first)
    guard actualHeader == header else {
      throw CorpusManifestError.invalidHeader(actualHeader)
    }

    return try lines.dropFirst().enumerated().map { offset, line in
      let lineNumber = offset + 2
      let fields = split(line)
      guard fields.count == header.count else {
        throw CorpusManifestError.invalidFieldCount(line: lineNumber, actual: fields.count)
      }
      guard let start = Double(fields[4]), let end = Double(fields[5]) else {
        throw CorpusManifestError.invalidTimestamp(line: lineNumber)
      }
      guard start >= 0, end >= start else {
        throw CorpusManifestError.invalidTimeRange(line: lineNumber)
      }

      let audioURL: URL
      if fields[2].hasPrefix("/") {
        audioURL = URL(fileURLWithPath: fields[2])
      } else {
        audioURL = baseURL.appendingPathComponent(fields[2])
      }

      return CorpusSample(
        id: fields[0],
        dataset: fields[1],
        audioURL: audioURL.standardizedFileURL,
        reference: fields[3],
        speechStartMilliseconds: start,
        speechEndMilliseconds: end
      )
    }
  }

  private static func split(_ line: String) -> [String] {
    line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
  }
}

public enum CharacterErrorRate {
  private static let ignoredSentencePunctuation: Set<Character> = [
    "、", "。", "，", "．", "！", "？", "「", "」", "『", "』", "“", "”", "‘", "’", ",", "!", "?"
  ]

  public static func calculate(reference: String, hypothesis: String) -> Double {
    let referenceCharacters = normalizedCharacters(reference)
    let hypothesisCharacters = normalizedCharacters(hypothesis)
    guard !referenceCharacters.isEmpty else {
      return hypothesisCharacters.isEmpty ? 0 : 1
    }
    return Double(editDistance(referenceCharacters, hypothesisCharacters))
      / Double(referenceCharacters.count)
  }

  private static func normalizedCharacters(_ text: String) -> [Character] {
    Array(
      text.precomposedStringWithCompatibilityMapping
        .filter { !$0.isWhitespace && !ignoredSentencePunctuation.contains($0) }
    )
  }

  private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
    var previous = Array(0...rhs.count)
    for (lhsIndex, lhsCharacter) in lhs.enumerated() {
      var current = [lhsIndex + 1]
      current.reserveCapacity(rhs.count + 1)
      for (rhsIndex, rhsCharacter) in rhs.enumerated() {
        current.append(
          min(
            current[rhsIndex] + 1,
            previous[rhsIndex + 1] + 1,
            previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
          )
        )
      }
      previous = current
    }
    return previous[rhs.count]
  }
}

public enum LatencyJudgement: String, Codable, Equatable, Sendable {
  case pass
  case acceptable
  case fail
  case notMeasured = "not_measured"

  public static func classify(milliseconds: Double?) -> Self {
    guard let milliseconds else { return .notMeasured }
    if milliseconds <= 400 { return .pass }
    if milliseconds <= 600 { return .acceptable }
    return .fail
  }
}

public struct BenchmarkOptions: Equatable, Sendable {
  public let engine: BenchmarkEngine
  public let manifestURL: URL
  public let outputURL: URL
  public let modelDirectory: URL?
  public let limit: Int?
  public let allowDownloads: Bool
  public let debug: Bool

  public static func parse(
    _ arguments: [String],
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> Self {
    var values: [String: String] = [:]
    var allowDownloads = false
    var debug = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--allow-downloads" {
        allowDownloads = true
        index += 1
        continue
      }
      if argument == "--debug" {
        debug = true
        index += 1
        continue
      }
      guard ["--engine", "--manifest", "--output", "--model-dir", "--limit"].contains(argument),
        index + 1 < arguments.count
      else {
        throw BenchmarkOptionsError.invalidArgument(argument)
      }
      values[argument] = arguments[index + 1]
      index += 2
    }

    guard let engineValue = values["--engine"], let engine = BenchmarkEngine(rawValue: engineValue)
    else {
      throw BenchmarkOptionsError.missingOrInvalid("--engine")
    }
    guard let manifestPath = values["--manifest"] else {
      throw BenchmarkOptionsError.missingOrInvalid("--manifest")
    }
    guard let outputPath = values["--output"] else {
      throw BenchmarkOptionsError.missingOrInvalid("--output")
    }

    let limit: Int?
    if let rawLimit = values["--limit"] {
      guard let parsed = Int(rawLimit), parsed > 0 else {
        throw BenchmarkOptionsError.missingOrInvalid("--limit")
      }
      limit = parsed
    } else {
      limit = nil
    }

    return Self(
      engine: engine,
      manifestURL: fileURL(manifestPath, relativeTo: workingDirectory),
      outputURL: fileURL(outputPath, relativeTo: workingDirectory),
      modelDirectory: values["--model-dir"].map { fileURL($0, relativeTo: workingDirectory) },
      limit: limit,
      allowDownloads: allowDownloads,
      debug: debug
    )
  }

  private static func fileURL(_ path: String, relativeTo workingDirectory: URL) -> URL {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
    return workingDirectory.appendingPathComponent(path).standardizedFileURL
  }
}

public enum BenchmarkOptionsError: LocalizedError, Equatable {
  case invalidArgument(String)
  case missingOrInvalid(String)

  public var errorDescription: String? {
    switch self {
    case .invalidArgument(let argument):
      return "invalid or incomplete argument: \(argument)"
    case .missingOrInvalid(let option):
      return "missing or invalid required option: \(option)"
    }
  }
}

public struct BenchmarkRecord: Codable, Equatable, Sendable {
  public let schemaVersion = 1
  public let engine: BenchmarkEngine
  public let dataset: String
  public let sampleID: String
  public let reference: String
  public let hypothesis: String
  public let firstTokenLatencyMilliseconds: Double?
  public let finalLatencyMilliseconds: Double?
  public let characterErrorRate: Double?
  public let idleRSSBytes: UInt64?
  public let peakRSSBytes: UInt64?
  public let firstModelLoadMilliseconds: Double?
  public let warmModelLoadMilliseconds: Double?
  public let error: String?

  public init(
    engine: BenchmarkEngine,
    dataset: String,
    sampleID: String,
    reference: String,
    hypothesis: String,
    firstTokenLatencyMilliseconds: Double?,
    finalLatencyMilliseconds: Double?,
    characterErrorRate: Double?,
    idleRSSBytes: UInt64?,
    peakRSSBytes: UInt64?,
    firstModelLoadMilliseconds: Double?,
    warmModelLoadMilliseconds: Double?,
    error: String?
  ) {
    self.engine = engine
    self.dataset = dataset
    self.sampleID = sampleID
    self.reference = reference
    self.hypothesis = hypothesis
    self.firstTokenLatencyMilliseconds = firstTokenLatencyMilliseconds
    self.finalLatencyMilliseconds = finalLatencyMilliseconds
    self.characterErrorRate = characterErrorRate
    self.idleRSSBytes = idleRSSBytes
    self.peakRSSBytes = peakRSSBytes
    self.firstModelLoadMilliseconds = firstModelLoadMilliseconds
    self.warmModelLoadMilliseconds = warmModelLoadMilliseconds
    self.error = error
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case engine
    case dataset
    case sampleID = "sample_id"
    case reference
    case hypothesis
    case firstTokenLatencyMilliseconds = "first_token_latency_ms"
    case finalLatencyMilliseconds = "final_latency_ms"
    case characterErrorRate = "cer"
    case idleRSSBytes = "idle_rss_bytes"
    case peakRSSBytes = "peak_rss_bytes"
    case firstModelLoadMilliseconds = "model_load_first_ms"
    case warmModelLoadMilliseconds = "model_load_warm_ms"
    case error
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(engine, forKey: .engine)
    try container.encode(dataset, forKey: .dataset)
    try container.encode(sampleID, forKey: .sampleID)
    try container.encode(reference, forKey: .reference)
    try container.encode(hypothesis, forKey: .hypothesis)
    try container.encodeOptional(
      firstTokenLatencyMilliseconds, forKey: .firstTokenLatencyMilliseconds)
    try container.encodeOptional(finalLatencyMilliseconds, forKey: .finalLatencyMilliseconds)
    try container.encodeOptional(characterErrorRate, forKey: .characterErrorRate)
    try container.encodeOptional(idleRSSBytes, forKey: .idleRSSBytes)
    try container.encodeOptional(peakRSSBytes, forKey: .peakRSSBytes)
    try container.encodeOptional(firstModelLoadMilliseconds, forKey: .firstModelLoadMilliseconds)
    try container.encodeOptional(warmModelLoadMilliseconds, forKey: .warmModelLoadMilliseconds)
    try container.encodeOptional(error, forKey: .error)
  }
}

extension KeyedEncodingContainer {
  fileprivate mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
    if let value {
      try encode(value, forKey: key)
    } else {
      try encodeNil(forKey: key)
    }
  }
}

extension JSONEncoder {
  public static var m0: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

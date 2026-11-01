import Darwin
import Foundation
import VoxCore

/// speech.cpp 4 の C ABI。CPU 1 スレッドで新着音声だけを判定する。
final class HaasVAD {
  private typealias Pointer = OpaquePointer
  private typealias Create = @convention(c) (UnsafeMutablePointer<Pointer?>) -> Int32
  private typealias Free = @convention(c) (Pointer?) -> Void
  private typealias SetThreads = @convention(c) (Pointer?, Int32) -> Int32
  private typealias SetDevice = @convention(c) (Pointer?, UnsafePointer<CChar>) -> Int32
  private typealias Load = @convention(c) (UnsafePointer<CChar>, Pointer?, UnsafeMutablePointer<Pointer?>) -> Int32
  private typealias NewRequest = @convention(c) (Pointer?, UnsafeMutablePointer<Pointer?>) -> Int32
  private typealias SetInt = @convention(c) (Pointer?, Int32, Int64) -> Int32
  private typealias SetFloat = @convention(c) (Pointer?, Int32, Double) -> Int32
  private typealias Start = @convention(c) (Pointer?, Int32, UnsafeMutablePointer<Pointer?>) -> Int32
  private typealias Push = @convention(c) (Pointer?, UnsafePointer<Float>?, Int) -> Int32
  private typealias Count = @convention(c) (Pointer?) -> Int
  private typealias Region = @convention(c) (Pointer?, Int, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>) -> Int32
  private typealias Speaking = @convention(c) (Pointer?, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Int32>) -> Int32
  private typealias Log = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
  private typealias SetLog = @convention(c) (Log?, UnsafeMutableRawPointer?) -> Void

  private let library: SpeechLibrary
  private let modelFree: Free
  private let requestNew: NewRequest
  private let requestFree: Free
  private let setInt: SetInt
  private let setFloat: SetFloat
  private let detectionStart: Start
  private let detectionFree: Free
  private let push: Push
  private let regionCount: Count
  private let region: Region
  private let speaking: Speaking
  private var model: Pointer?
  private var detection: Pointer?
  private var gate = SpeechGate()
  var windowStartFrame: Int? { gate.windowStartFrame }

  init(library url: URL, model modelURL: URL) throws {
    let library = try SpeechLibrary(url: url)
    self.library = library
    let version: @convention(c) () -> Int32 = try library.function("speech_api_version_major")
    guard version() == 4 else { throw HaasError.invalidAsset }
    let setLog: SetLog = try library.function("speech_log_set")
    setLog({ _, _, _ in }, nil)
    let paramsNew: Create = try library.function("speech_load_params_new")
    let paramsFree: Free = try library.function("speech_load_params_free")
    let threads: SetThreads = try library.function("speech_load_params_set_threads")
    let device: SetDevice = try library.function("speech_load_params_set_device")
    let load: Load = try library.function("speech_model_load")
    modelFree = try library.function("speech_model_free")
    requestNew = try library.function("speech_request_new")
    requestFree = try library.function("speech_request_free")
    setInt = try library.function("speech_request_set_int")
    setFloat = try library.function("speech_request_set_float")
    detectionStart = try library.function("speech_detection_start")
    detectionFree = try library.function("speech_detection_free")
    push = try library.function("speech_detection_push")
    regionCount = try library.function("speech_detection_region_count")
    region = try library.function("speech_detection_region")
    speaking = try library.function("speech_detection_speaking")
    var params: Pointer?
    try Self.check(paramsNew(&params))
    defer { paramsFree(params) }
    try Self.check(threads(params, 1))
    try Self.check(device(params, "CPU"))
    try Self.check(load(modelURL.path, params, &model))
  }

  deinit {
    detectionFree(detection)
    modelFree(model)
  }

  func reset() {
    detectionFree(detection)
    detection = nil
    gate = SpeechGate()
  }

  func begin(windowStartFrame: Int) throws {
    reset()
    var request: Pointer?
    try Self.check(requestNew(model, &request))
    defer { requestFree(request) }
    // 短い返事を残し、発話の前後は 160ms 保持する。
    try Self.check(setFloat(request, 39, 0.4))
    try Self.check(setInt(request, 40, 32))
    try Self.check(setInt(request, 41, 320))
    try Self.check(setInt(request, 42, 160))
    try Self.check(detectionStart(request, 16000, &detection))
    gate.begin(windowStartFrame: windowStartFrame)
  }

  func audioToRecognize(_ pcm: Data) throws -> Data? {
    let frames = pcm.count / 2
    guard detection != nil, frames >= gate.processedFrames, pcm.count.isMultiple(of: 2) else {
      throw HaasError.recognitionFailed
    }
    if frames > gate.processedFrames {
      let samples: [Float] = pcm.withUnsafeBytes { bytes in
        (gate.processedFrames..<frames).map {
          // 小声の判定だけを増幅する。ASR と保存へ渡す音声の音量は変えない。
          let value = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 4096
          return max(-1, min(1, value))
        }
      }
      try samples.withUnsafeBufferPointer { try Self.check(push(detection, $0.baseAddress, $0.count)) }
      gate.advance(to: frames)
    }
    let regions = try finalizedRegions()
    var start = 0.0
    var kept: Int32 = 0
    let active = speaking(detection, &start, &kept) != 0 && kept != 0
    guard let ranges = gate.recognitionRanges(
      regions: regions, speakingFrom: active ? frame(start) : nil, availableFrames: frames)
    else { return nil }
    return ranges.reduce(into: Data()) { result, range in
      result.append(pcm.subdata(in: (range.lowerBound * 2)..<(range.upperBound * 2)))
    }
  }

  private func finalizedRegions() throws -> [Range<Int>] {
    try (0..<regionCount(detection)).map { index in
      var start = 0.0
      var end = 0.0
      try Self.check(region(detection, index, &start, &end))
      return frame(start)..<frame(end)
    }
  }

  private func frame(_ seconds: Double) -> Int { max(0, Int((seconds * 16000).rounded())) }

  private static func check(_ status: Int32) throws {
    guard status == 0 else { throw HaasError.recognitionFailed }
  }
}

private final class SpeechLibrary {
  private let handle: UnsafeMutableRawPointer

  init(url: URL) throws {
    guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw HaasError.invalidAsset }
    self.handle = handle
  }

  deinit { dlclose(handle) }

  func function<T>(_ name: String) throws -> T {
    guard let symbol = dlsym(handle, name) else { throw HaasError.invalidAsset }
    return unsafeBitCast(symbol, to: T.self)
  }
}

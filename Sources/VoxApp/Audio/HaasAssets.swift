import CryptoKit
import Darwin
import Foundation
import VoxCore

enum HaasError: Error, CustomStringConvertible {
  case downloadFailed
  case invalidAsset
  case workerUnavailable
  case invalidResponse
  case timedOut
  case recognitionFailed
  case audioBacklog

  var description: String {
    switch self {
    case .downloadFailed: "Haasのモデルを取得できませんでした。接続を確認するか、設定でAppleに切り替えてください"
    case .invalidAsset: "Haasのファイルを検証できませんでした。モデルを取得し直すか、設定でAppleに切り替えてください"
    case .workerUnavailable: "Haasを起動できませんでした。設定でAppleに切り替えてください"
    case .invalidResponse: "Haasの応答を読み取れませんでした。録音をやり直すか、設定でAppleに切り替えてください"
    case .timedOut: "Haasの応答がありません。録音をやり直すか、設定でAppleに切り替えてください"
    case .recognitionFailed: "Haasで認識できませんでした。録音をやり直すか、設定でAppleに切り替えてください"
    case .audioBacklog: "Haasの処理が音声に追いつきません。設定でAppleに切り替えてください"
    }
  }
}

/// 配布物を固定し、音声を含まない取得だけを行う。呼び出しは HaasWorker の actor 上。
struct HaasAssets: Sendable {
  private static let verifier = HaasAssetVerifier()
  static let modelName = "Haas-616M-ja-v1.0-Q4_K.gguf"
  static let modelSHA256 = "d24d53f29b75214a933ff482b0de1217e0a800f4118cca39ad6cf03609a89d6f"
  static let runtimeSHA256 = "f344cf59d72b5f91f5838df68c37cae739f80ae0b4f141bc553a81ffde9547bd"
  static let archiveSHA256 = "4f48ac4aefe65a00e2724e94749f01f7993de6190998c49bb347662f96f7af6d"
  static let librarySHA256 = "e3fac058886bc215cb237a6745fced4d1555263808569998a42478fc889d85b6"
  static let vadSHA256 = "2fc312514e5fc4fa4ffd02b25c76a4853fa4130e8fb9777d01502183b01238cb"
  static let vadName = "silero-vad-309K-v6.2-F32.gguf"
  static let vadURL = URL(
    string: "https://huggingface.co/sakasegawa/silero-vad-GGUF/resolve/7fcb7aa2a70c312f8579fc987b3e1cdecf9321ca/silero-vad-309K-v6.2-F32.gguf")!
  static let revision = "6b965d5007ba780585de51549d57a8c1c0d67c7e"
  static let runtimeURL = URL(
    string: "https://github.com/nyosegawa/speech.cpp/releases/download/v0.10.0/speech-0.10.0-macos-arm64-metal.zip")!
  static let modelURL = URL(
    string: "https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF/resolve/\(revision)/\(modelName)")!

  let root: URL
  var executable: URL { root.appendingPathComponent("speech-0.10.0") }
  var model: URL { root.appendingPathComponent(Self.modelName) }
  var vadModel: URL { root.appendingPathComponent(Self.vadName) }
  private var bundledLibrary: URL? {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
    return Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libspeech.4.dylib")
  }
  var library: URL { bundledLibrary ?? root.appendingPathComponent("libspeech.4.dylib") }

  static var standard: Self {
    Self(root: RecordingStore.standard.root.deletingLastPathComponent().appendingPathComponent("models/haas-v1-q4"))
  }

  func prepare(
    allowDownload: Bool = true, onProgress: @Sendable (SpeechPreparationStage) async -> Void = { _ in }
  ) async throws {
    await onProgress(.checkingFiles)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let runtimeMissing = try await !Self.verifier.matches(executable, sha256: Self.runtimeSHA256)
    let libraryMissing = if bundledLibrary == nil {
      try await !Self.verifier.matches(library, sha256: Self.librarySHA256)
    } else { false }
    if runtimeMissing || libraryMissing {
      guard allowDownload else { throw HaasError.invalidAsset }
      await onProgress(.downloading)
      try await installRuntime()
    }
    guard FileManager.default.fileExists(atPath: library.path) else { throw HaasError.invalidAsset }
    if try await !Self.verifier.matches(model, sha256: Self.modelSHA256) {
      guard allowDownload else { throw HaasError.invalidAsset }
      await onProgress(.downloading)
      try await download(Self.modelURL, to: model, sha256: Self.modelSHA256)
    }
    if try await !Self.verifier.matches(vadModel, sha256: Self.vadSHA256) {
      guard allowDownload else { throw HaasError.invalidAsset }
      await onProgress(.downloading)
      try await download(Self.vadURL, to: vadModel, sha256: Self.vadSHA256)
    }
    try Task.checkCancellation()
  }

  static func matches(_ file: URL, sha256: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: file.path) else { return false }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      try Task.checkCancellation()
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256
  }

  private func installRuntime() async throws {
    let staging = root.appendingPathComponent("install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let archive = staging.appendingPathComponent("runtime.zip")
    try await download(Self.runtimeURL, to: archive, sha256: Self.archiveSHA256)
    // .app のライブラリは本体と同じ署名で同梱する。非 bundle 実行時だけキャッシュへ展開する。
    let files = bundledLibrary == nil ? ["speech", "libspeech.4.dylib"] : ["speech"]
    let result = ProcessRunner.run(
      executable: "/usr/bin/unzip", arguments: ["-j", "-qq", archive.path] + files + ["-d", staging.path],
      timeout: .seconds(30), outputLimit: 4096)
    guard result.termination == .exited(0) else { throw HaasError.invalidAsset }
    let binary = staging.appendingPathComponent("speech")
    guard try Self.matches(binary, sha256: Self.runtimeSHA256) else { throw HaasError.invalidAsset }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    try replace(binary, at: executable)
    if bundledLibrary == nil {
      let downloadedLibrary = staging.appendingPathComponent("libspeech.4.dylib")
      guard try Self.matches(downloadedLibrary, sha256: Self.librarySHA256) else { throw HaasError.invalidAsset }
      try replace(downloadedLibrary, at: library)
    }
  }

  private func download(_ url: URL, to destination: URL, sha256: String) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 900
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (temporary, response) = try await session.download(from: url)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HaasError.downloadFailed }
    guard try Self.matches(temporary, sha256: sha256) else { throw HaasError.invalidAsset }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    try replace(temporary, at: destination)
  }

  private func replace(_ source: URL, at destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    } else {
      try FileManager.default.moveItem(at: source, to: destination)
    }
  }
}

actor HaasAssetVerifier {
  private struct Time: Equatable {
    let seconds: Int
    let nanoseconds: Int
    init(_ value: timespec) { seconds = value.tv_sec; nanoseconds = value.tv_nsec }
  }

  private struct Fingerprint: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: Time
    let changed: Time

    init(_ file: URL) throws {
      var info = stat()
      guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw HaasError.invalidAsset }
      device = info.st_dev
      inode = info.st_ino
      size = info.st_size
      modified = Time(info.st_mtimespec)
      changed = Time(info.st_ctimespec)
    }
  }

  private struct Entry {
    let digest: String
    let fingerprint: Fingerprint
  }

  private var verified: [URL: Entry] = [:]

  func matches(_ file: URL, sha256: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: file.path) else {
      verified[file] = nil
      return false
    }
    let before = try Fingerprint(file)
    if let entry = verified[file], entry.digest == sha256, entry.fingerprint == before { return true }
    verified[file] = nil
    guard try HaasAssets.matches(file, sha256: sha256) else { return false }
    guard try Fingerprint(file) == before else { throw HaasError.invalidAsset }
    verified[file] = Entry(digest: sha256, fingerprint: before)
    return true
  }
}

import CryptoKit
import Foundation
import Testing
@testable import VoxApp

@Suite("Haas: 検証済みファイルの再利用")
struct HaasAssetVerifierTests {
  @Test("先読みは未取得のモデルをダウンロードしない")
  func cachedPreparationDoesNotDownload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vox-cached-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let assets = HaasAssets(root: root)
    await #expect(throws: HaasError.invalidAsset) { try await assets.prepare(allowDownload: false) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("検証を再利用しても、同じサイズと更新日時に戻した改変を見逃さない")
  func changedContentsAreRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vox-asset-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("model")
    let original = Data("alpha".utf8)
    let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    try original.write(to: file)
    let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    let verifier = HaasAssetVerifier()
    #expect(try await verifier.matches(file, sha256: digest))
    #expect(try await verifier.matches(file, sha256: digest))
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data("bravo".utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    #expect(try await !verifier.matches(file, sha256: digest))
    try original.write(to: file, options: .atomic)
    #expect(try await verifier.matches(file, sha256: digest))
    #expect(try await !verifier.matches(file, sha256: String(repeating: "0", count: 64)))
  }
}

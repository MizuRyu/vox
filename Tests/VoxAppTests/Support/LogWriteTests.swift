// B-2。診断ログの書き込み。ディスク満杯などで書けない回に本体を落とさない
// （閉じた fd を「書けない書き込み先」として使う）。

import Foundation
import Testing
@testable import VoxApp

@Suite("Support: 診断ログの書き込み")
struct LogWriteTests {
  @Test("書けない書き込み先でも例外を投げず、書ける先には 1 行書く")
  func unwritableDestinationDoesNotCrash() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-log-write-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("vox.log")
    FileManager.default.createFile(atPath: url.path, contents: nil)

    let handle = try FileHandle(forWritingTo: url)
    voxWriteLog("first", to: handle)
    try handle.close()
    voxWriteLog("after close", to: handle)
    voxWrite(Data("after close, raw\n".utf8), to: handle)

    #expect(try String(contentsOf: url, encoding: .utf8) == "first\n", "書けた行が違う")
  }

  // B-5。リポジトリの位置と選んだファイル名は本文と同じ扱い。
  @MainActor
  @Test("パスは --log-text の回だけ診断ログに出る")
  func pathsAreOnlyLoggedWithTheTextOption() {
    let logFinalText = VoxConfig.logFinalText
    defer { VoxConfig.logFinalText = logFinalText }

    VoxConfig.logFinalText = false
    #expect(voxLoggable(path: "/Users/me/dev/secret") == "-", "既定でパスが出ている")
    VoxConfig.logFinalText = true
    #expect(voxLoggable(path: "/Users/me/dev/secret") == "/Users/me/dev/secret", "パスが出ない")
  }
}

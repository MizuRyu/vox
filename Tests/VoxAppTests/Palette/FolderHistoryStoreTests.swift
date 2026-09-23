// T23 folders.json の読み書き。本体の既定パスには触らず一時パスで確かめる。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@Suite("Palette: フォルダ履歴の保存")
struct FolderHistoryStoreTests {
  /// 一時ディレクトリに folders.json を置き、終わったら片付ける。
  private func withStore(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vox-folders-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previous = FolderHistoryStore.path
    FolderHistoryStore.path = directory.appendingPathComponent("folders.json").path
    defer {
      FolderHistoryStore.path = previous
      try? FileManager.default.removeItem(at: directory)
    }
    try body(directory)
  }

  @Test("Recorded folders survive A round trip and drop the ones that are gone")
  func recordedFoldersSurviveARoundTripAndDropTheOnesThatAreGone() throws {
    try withStore { directory in
      let kept = directory.appendingPathComponent("kept")
      let gone = directory.appendingPathComponent("gone")
      for url in [kept, gone] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      FolderHistoryStore.record(gone.path, at: Date(timeIntervalSince1970: 1_700_000_000))
      FolderHistoryStore.record(kept.path, at: Date(timeIntervalSince1970: 1_700_000_010))
      #expect(
        FolderHistoryStore.load().entries.map(\.path) == [kept.path, gone.path],
        "書いたフォルダが読み戻せていない: \(FolderHistoryStore.load().entries.map(\.path))")

      try FileManager.default.removeItem(at: gone)
      #expect(
        FolderHistoryStore.load().entries.map(\.path) == [kept.path],
        "消えたフォルダを読み込みで落としていない")
    }
  }

  @Test("A missing file reads as an empty history")
  func aMissingFileReadsAsAnEmptyHistory() throws {
    try withStore { _ in
      #expect(FolderHistoryStore.load().entries.isEmpty, "無いファイルから中身を作った")
    }
  }

  @Test("The file is rewritten in place instead of appended")
  func theFileIsRewrittenInPlaceInsteadOfAppended() throws {
    try withStore { directory in
      let folder = directory.appendingPathComponent("repo")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      FolderHistoryStore.record(folder.path, at: Date(timeIntervalSince1970: 1_700_000_000))
      FolderHistoryStore.record(folder.path, at: Date(timeIntervalSince1970: 1_700_000_010))
      let data = try Data(contentsOf: URL(fileURLWithPath: FolderHistoryStore.path))
      let text = try #require(String(data: data, encoding: .utf8))
      #expect(!text.contains("}{"), "追記になっている（1 つの JSON になっていない）")
      let entries = FolderHistoryStore.load().entries
      #expect(entries.count == 1 && entries.first?.useCount == 2, "回数が足されていない: \(entries)")
    }
  }
}

// プレビューの読み出し。根の外・通常ファイル以外・上限を越える中身を拒む。

import Darwin
import Foundation
import Testing
import VoxCore

@Suite("Palette: プレビューの読み出し")
struct BoundedFileReaderTests {
  @MainActor
  @Test("Bounded regular file preview")
  func testBoundedRegularFilePreview() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("normal.txt")
    let content = (1...50).map { "line \($0)" }.joined(separator: "\n")
    try Data(content.utf8).write(to: file)
    let preview = BoundedFileReader.read(
      root: root.path, relativePath: "normal.txt", byteLimit: 64 * 1024, lineLimit: 40)
    #expect(preview.status == .text, "regular UTF-8 file is previewed")
    #expect(preview.lines.count == 40, "preview is limited to 40 lines")
  }

  @MainActor
  @Test("Bounded reader rejects special and outside files")
  func testBoundedReaderRejectsSpecialAndOutsideFiles() throws {
    let root = try temporaryDirectory()
    let outside = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let secret = outside.appendingPathComponent("secret.txt")
    try Data("secret".utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"), withDestinationURL: secret)
    #expect(
      BoundedFileReader.read(root: root.path, relativePath: secret.path).status == .outsideRoot,
      "absolute outside path is rejected")
    #expect(
      BoundedFileReader.read(
        root: root.path, relativePath: "../\(outside.lastPathComponent)/secret.txt"
      ).status == .outsideRoot,
      "parent traversal is rejected")
    #expect(
      BoundedFileReader.read(root: root.path, relativePath: "link").status == .outsideRoot,
      "symlink outside root is rejected")

    let fifo = root.appendingPathComponent("pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture is created")
    let start = ContinuousClock.now
    let result = BoundedFileReader.read(root: root.path, relativePath: "pipe")
    #expect(result.status == .notRegularFile, "FIFO is rejected")
    #expect(start.duration(to: .now) < .seconds(1), "FIFO preview does not block")
    #expect(
      BoundedFileReader.read(root: root.path, relativePath: ".").status == .notRegularFile,
      "directory is rejected")
    #expect(
      BoundedFileReader.read(root: root.path, relativePath: "/dev/null").status == .outsideRoot,
      "device outside root is rejected")
  }

  @MainActor
  @Test("Sparse file and UTF 8 boundary are bounded")
  func testSparseFileAndUTF8BoundaryAreBounded() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sparse = root.appendingPathComponent("sparse")
    #expect(
      FileManager.default.createFile(atPath: sparse.path, contents: Data("head".utf8)),
      "sparse fixture is created")
    let handle = try FileHandle(forWritingTo: sparse)
    try handle.truncate(atOffset: 1_000_000_000)
    try handle.close()
    let result = BoundedFileReader.read(
      root: root.path, relativePath: "sparse", byteLimit: 64 * 1024, lineLimit: 40)
    #expect(result.bytesRead <= 64 * 1024, "sparse file read stays bounded")

    let utf8 = root.appendingPathComponent("utf8")
    try Data("abcé".utf8).write(to: utf8)
    let utf8Result = BoundedFileReader.read(
      root: root.path, relativePath: "utf8", byteLimit: 4, lineLimit: 40)
    #expect(
      utf8Result.status == .text && utf8Result.lines == ["abc"], "partial UTF-8 suffix is discarded")

    let malformed = root.appendingPathComponent("malformed")
    try Data([0x61, 0xff]).write(to: malformed)
    let malformedResult = BoundedFileReader.read(
      root: root.path, relativePath: "malformed", byteLimit: 64, lineLimit: 40)
    #expect(malformedResult.status == .invalidEncoding, "invalid UTF-8 at EOF is not silently removed")
  }
}

// T20 ペーストのパス表示。

import Foundation
import Testing
import VoxCore

@Suite("Palette: パス表示")
struct FilePathFormatTests {
  @Test("Path inside the repository becomes relative")
  func pathInsideTheRepositoryBecomesRelative() throws {
    let text = FilePathFormat.display(
      path: "/Users/vox/repo/Sources/Vox/App.swift", repositoryRoot: "/Users/vox/repo",
      homeDirectory: "/Users/vox")
    #expect(text == "Sources/Vox/App.swift", "リポジトリ配下が相対パスになっていない: \(text)")
  }

  @Test("Path outside the repository is shortened with tilde")
  func pathOutsideTheRepositoryIsShortenedWithTilde() throws {
    let text = FilePathFormat.display(
      path: "/Users/vox/Desktop/shot.png", repositoryRoot: "/Users/vox/repo",
      homeDirectory: "/Users/vox")
    #expect(text == "~/Desktop/shot.png", "~ に短縮されていない: \(text)")
  }

  /// リポジトリが未解決なら絶対パス（ホーム配下は `~` にする）。
  @Test("Path without A repository is absolute")
  func pathWithoutARepositoryIsAbsolute() throws {
    let text = FilePathFormat.display(
      path: "/Users/vox/repo/README.md", repositoryRoot: nil, homeDirectory: "/Users/vox")
    #expect(text == "~/repo/README.md", "未解決時のパスが違う: \(text)")
  }

  @Test("Path outside the home directory stays absolute")
  func pathOutsideTheHomeDirectoryStaysAbsolute() throws {
    let text = FilePathFormat.display(
      path: "/tools/bin/vox", repositoryRoot: "/Users/vox/repo", homeDirectory: "/Users/vox")
    #expect(text == "/tools/bin/vox", "ホーム外を短縮してしまった: \(text)")
  }

  // A-3。索引の列挙で使う相対化。root の末尾 `/` と、実体解決済みのパスを取り違えない。
  @Test("Relative path ignores A trailing slash on the root")
  func relativePathIgnoresATrailingSlashOnTheRoot() throws {
    #expect(
      FilePathFormat.relative(path: "/private/tmp/probe/sub/b.txt", root: "/private/tmp/probe/")
        == "sub/b.txt", "末尾の / で相対パスがずれた")
    #expect(
      FilePathFormat.relative(path: "/private/tmp/probe/a.txt", root: "/private/tmp/probe")
        == "a.txt", "相対パスが違う")
  }

  @Test("Relative path rejects paths outside the root")
  func relativePathRejectsPathsOutsideTheRoot() throws {
    #expect(
      FilePathFormat.relative(path: "/private/tmp/probe/a.txt", root: "/tmp/probe") == nil,
      "実体解決前の root で相対化してしまった")
    #expect(
      FilePathFormat.relative(path: "/private/tmp/probe2/a.txt", root: "/private/tmp/probe")
        == nil, "前方一致だけで別ディレクトリを取り込んだ")
    #expect(
      FilePathFormat.relative(path: "/private/tmp/probe", root: "/private/tmp/probe") == nil,
      "root 自身を相対パスにした")
  }

  @Test("Multiple files are joined with A single space")
  func multipleFilesAreJoinedWithASingleSpace() throws {
    let text = FilePathFormat.insertion(
      paths: ["/Users/vox/repo/a.swift", "/Users/vox/b.txt", ""],
      repositoryRoot: "/Users/vox/repo", homeDirectory: "/Users/vox")
    #expect(text == "a.swift ~/b.txt", "空白区切りになっていない: \(text)")
  }
}

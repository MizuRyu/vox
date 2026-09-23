// ADR-015 方式 C。前面アプリから決まらなかったときの順序:
// `--repo` → 最近使ったフォルダ → カレントディレクトリ。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@Suite("Palette: 決まらないときの検索対象")
struct TargetResolverTests {
  private func withDirectories(_ names: [String], _ body: ([String]) async throws -> Void)
    async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vox-target-\(UUID().uuidString)")
    var paths: [String] = []
    for name in names {
      let directory = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      paths.append(directory.path)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(paths)
  }

  /// 前面アプリを知らない回（`bundleIdentifier` が nil）だけを見る。
  private func resolve(repositories: [String], recentFolder: String?) async -> PaletteTarget? {
    await PaletteTargetResolver.resolve(
      bundleIdentifier: nil, processID: nil, fallbackRepositories: repositories,
      recentFolder: recentFolder)
  }

  @Test("The configured repository comes before the recent folder")
  func theConfiguredRepositoryComesBeforeTheRecentFolder() async throws {
    try await withDirectories(["repo", "recent"]) { paths in
      let target = await resolve(repositories: [paths[0]], recentFolder: paths[1])
      #expect(
        target == PaletteTarget(root: paths[0], source: .fallback),
        "--repo より最近使ったフォルダを先にした: \(String(describing: target))")
    }
  }

  @Test("Without a configured repository the recent folder is the target")
  func withoutAConfiguredRepositoryTheRecentFolderIsTheTarget() async throws {
    try await withDirectories(["recent"]) { paths in
      let target = await resolve(repositories: [], recentFolder: paths[0])
      #expect(
        target == PaletteTarget(root: paths[0], source: .recent),
        "最近使ったフォルダに落ちていない: \(String(describing: target))")
    }
  }

  @Test("A recent folder that is gone falls through to the current directory")
  func aRecentFolderThatIsGoneFallsThroughToTheCurrentDirectory() async throws {
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = true
    defer { VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory }

    let target = await resolve(repositories: [], recentFolder: "/nonexistent/recent/folder")
    #expect(target?.source == .fallback, "消えたフォルダを対象にした: \(String(describing: target))")
    #expect(
      target?.root == FileManager.default.currentDirectoryPath,
      "カレントディレクトリに落ちていない")
  }

  @Test("Nothing is resolved when the current directory is not allowed either")
  func nothingIsResolvedWhenTheCurrentDirectoryIsNotAllowedEither() async throws {
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory }

    #expect(
      await resolve(repositories: [], recentFolder: nil) == nil,
      "候補が無いのに対象を作った")
  }
}

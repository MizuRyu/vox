// 二重起動を止めるロックと、診断ログの出力先。どちらも通常ファイルにだけ非公開で書く。
// アプリも入力デバイスも開かず、利用者のログ先にも触らない。

import Darwin
import Foundation
import Testing
@testable import VoxApp

@Suite("Resident: 起動ロックとログの出力先")
struct InstanceLockTests {
  @Test("同時に 1 つだけがロックを持ち、通常ファイル以外は断る")
  func instanceLockChecks() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("vox-lock-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }

    let path = root.appendingPathComponent("resident.lock")
    var held: AppInstanceLock? = try AppInstanceLock(url: path)
    _ = withExtendedLifetime(held) {
      #expect("second instance rejected without stopping first") {
        _ = try AppInstanceLock(url: path)
      } throws: { error in
        guard case AppInstanceLock.LockError.alreadyRunning = error else { return false }
        return true
      }
    }
    held = nil
    let acquired = try AppInstanceLock(url: path)
    withExtendedLifetime(acquired) {}

    let attributes = try manager.attributesOfItem(atPath: path.path)
    #expect(
      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "lock mode is private")

    try expectRejectsUnsafeTargets(in: root) { _ = try AppInstanceLock(url: $0) }
  }

  @Test("診断ログは非公開の通常ファイルにだけ書く")
  func logRouterChecks() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("vox-log-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }
    let victim = root.appendingPathComponent("victim")
    try Data("keep".utf8).write(to: victim)

    // この検査プロセスの stderr だけを、一時的な非公開ディレクトリに向ける。
    let savedError = dup(STDERR_FILENO)
    defer { _ = dup2(savedError, STDERR_FILENO); close(savedError) }
    let support = root.appendingPathComponent("support")
    try manager.createDirectory(at: support, withIntermediateDirectories: false)
    var router: AppLogRouter? = try AppLogRouter.install(applicationSupport: support)
    withExtendedLifetime(router) {
      FileHandle.standardError.write(Data("diagnostic fixture\n".utf8))
    }
    let log = support.appendingPathComponent("vox/logs/vox.log")
    #expect(
      try Data(contentsOf: log) == Data("diagnostic fixture\n".utf8),
      "stderr routes to private app log")
    _ = dup2(savedError, STDERR_FILENO)
    router = nil
    let logAttributes = try manager.attributesOfItem(atPath: log.path)
    #expect(
      (logAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
      "diagnostic log mode is private")

    let redirectedSupport = root.appendingPathComponent("redirected-support")
    try manager.createDirectory(at: redirectedSupport, withIntermediateDirectories: false)
    try manager.createSymbolicLink(
      at: redirectedSupport.appendingPathComponent("vox"),
      withDestinationURL: support.appendingPathComponent("vox"))
    #expect(throws: (any Error).self, "intermediate log directory symlink refused") {
      _ = try AppLogRouter.install(applicationSupport: redirectedSupport)
    }
    try manager.removeItem(at: log)
    try manager.linkItem(at: victim, to: log)
    #expect(throws: (any Error).self, "hardlinked log refused") {
      _ = try AppLogRouter.install(applicationSupport: support)
    }
    #expect(
      try Data(contentsOf: victim) == Data("keep".utf8),
      "rejected logging preserves external target")
  }
}

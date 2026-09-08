// メインメニューの構成。⌘W が届くのは Window メニューに Close があるときだけ。

import AppKit
import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Test("メインメニューは Window の Close に ⌘W を持つ")
func mainMenuChecks() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vox-menu-checks-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
  try store.save(HotkeySettings())
  let settings = SettingsController(
    store: store, defaults: .standard, configuration: .standard)
  let coordinator = ResidentCoordinator(
    metricsPath: root.appendingPathComponent("metrics.jsonl").path,
    historyPath: root.appendingPathComponent("history.jsonl").path,
    settings: settings, settingsOnly: false, isBundled: false, log: nil, logError: nil)

  let menu = makeMainMenu(target: coordinator)
  let window = try #require(
    menu.items.first { $0.submenu?.title == "Window" }?.submenu,
    "the main menu has no Window menu")
  let close = try #require(
    window.items.first { $0.keyEquivalent == "w" }, "the Window menu has no ⌘W item")
  #expect(
    close.keyEquivalentModifierMask == NSEvent.ModifierFlags.command,
    "the Close item is not plain ⌘W")
  #expect(
    close.action == #selector(NSWindow.performClose(_:)),
    "the Close item does not close the key window")
}

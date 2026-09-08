// 設定ビューはウィンドウも権限も要らずに組み立てられる。

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Settings: ビューの組み立て")
struct SettingsViewTests {
  @Test("settings view can be built without windows or permissions")
  func settingsViewCanBeBuiltWithoutWindows() throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-settings-view-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
    try store.save(HotkeySettings())

    // 検査は 1 プロセスで走るので、他の検査が作った既存ウィンドウは許容し、新規生成だけを見る。
    let existingWindows = Set(application.windows.map(ObjectIdentifier.init))

    let model = SettingsModel(store: store, defaults: .standard)
    let view = NSHostingView(rootView: SettingsView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.width > 0 && view.fittingSize.height > 0, "empty settings view")
    let newWindows = Set(application.windows.map(ObjectIdentifier.init)).subtracting(existingWindows)
    #expect(newWindows.isEmpty, "settings inspection opened a window")
  }
}

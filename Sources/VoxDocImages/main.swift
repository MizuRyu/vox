// 合成データだけで README の画面例を描画する。画面のキャプチャ・録音・入力監視はしない。
import AppKit
import SwiftUI
import VoxCore
import VoxApp

@MainActor
func save<V: View>(_ content: V, size: CGSize, to url: URL) throws {
  let view = NSHostingView(rootView: content)
  view.frame = NSRect(origin: .zero, size: size)
  view.appearance = NSAppearance(named: .aqua)
  view.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
  view.layoutSubtreeIfNeeded()
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    throw CocoaError(.fileWriteUnknown)
  }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try png.write(to: url, options: .atomic)
}

@MainActor
func render() throws {
  let application = NSApplication.shared
  application.setActivationPolicy(.prohibited)
  let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "images", isDirectory: true)
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let settings = SettingsModel(
    store: SettingsStore(url: temporary.appendingPathComponent("settings.json")), defaults: .standard,
    microphoneProvider: {
      .available(devices: [
        MicrophoneDevice(id: 1, name: "内蔵マイク", transport: .builtIn),
        MicrophoneDevice(id: 2, name: "USB マイク", transport: .usb)
      ], defaultDeviceID: 1)
    })
  settings.toggleKey = "cmd+opt+space"
  settings.refreshMicrophones()
  let settingsView = SettingsView(model: settings)
    .background(Color(nsColor: .windowBackgroundColor))
  let settingsHeight: CGFloat = 780 // Show the scrollable settings form including its save controls.
  try save(settingsView, size: CGSize(width: 548, height: settingsHeight), to: output.appendingPathComponent("settings.png"))

  let model = HudModel()
  model.head = "次の変更では設定画面を整理します。"
  model.applyTentative("使いやすいショートカットで")
  model.tail = " Sources/App.swift"
  let hud = VStack(alignment: .leading, spacing: 12) {
    HStack(spacing: 10) {
      Circle().fill(.red).frame(width: 7, height: 7)
      Text("録音中").font(.system(size: 11, weight: .medium))
      Image(systemName: "waveform").foregroundStyle(.secondary)
      Spacer()
      Image(systemName: "gearshape").foregroundStyle(.secondary)
      Image(systemName: "chevron.down").foregroundStyle(.secondary)
    }
    TranscriptEditor(model: model).frame(height: 42)
    HStack(spacing: 16) {
      Text("⌘⌥Space  確定").font(.system(size: 10, design: .monospaced))
      Text("⌃P  ファイル").font(.system(size: 10, design: .monospaced))
      Text("esc  破棄").font(.system(size: 10, design: .monospaced))
    }.foregroundStyle(.secondary)
  }
  .padding(18)
  .frame(width: 680, height: 142)
  .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
  .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.15)))
  .padding(24)
  .background(Color(red: 0.94, green: 0.94, blue: 0.92))
  try save(hud, size: CGSize(width: 728, height: 190), to: output.appendingPathComponent("hud-example.png"))
  guard application.windows.allSatisfy({ !$0.isVisible }) else {
    throw CocoaError(.validationMissingMandatoryProperty)
  }
  print("Wrote synthetic settings.png and hud-example.png; visibleWindows=0")
}

do {
  try MainActor.assumeIsolated { try render() }
} catch {
  FileHandle.standardError.write(Data("Document rendering failed: \(error)\n".utf8))
  exit(1)
}

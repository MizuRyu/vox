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
  @Test("settings view can be built without windows or permissions", arguments: [
    MicrophoneInput.automatic, .systemDefault, .device("synthetic-builtin"), .device("synthetic-missing")
  ])
  func settingsViewCanBeBuiltWithoutWindows(microphoneInput: MicrophoneInput) throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-settings-view-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
    try store.save(HotkeySettings(microphoneInput: microphoneInput))

    // 検査は 1 プロセスで走るので、他の検査が作った既存ウィンドウは許容し、新規生成だけを見る。
    let existingWindows = Set(application.windows.map(ObjectIdentifier.init))

    let model = SettingsModel(
      store: store, defaults: .standard,
      dictionary: DictionaryStore(url: root.appendingPathComponent("dictionary.tsv")),
      microphoneProvider: {
        .available(devices: [
          MicrophoneDevice(id: 1, name: "Synthetic Built-in", transport: .builtIn, uid: "synthetic-builtin")
        ], defaultDeviceID: 1)
      })
    model.refreshMicrophones()
    model.refreshDictionary()
    let view = NSHostingView(rootView: SettingsView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.width > 0 && view.fittingSize.height > 0, "empty settings view")
    let newWindows = Set(application.windows.map(ObjectIdentifier.init)).subtracting(existingWindows)
    #expect(newWindows.isEmpty, "settings inspection opened a window")
  }

  /// 辞書の状態はファイルの有無・件数・壊れた行で変わる。文言は content-guidelines に従う。
  @Test("設定画面は辞書の件数と直す行番号を出す")
  func settingsShowTheDictionaryState() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-dictionary-view-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let settings = SettingsStore(url: root.appendingPathComponent("settings.json"))
    let dictionary = DictionaryStore(url: root.appendingPathComponent("dictionary.tsv"))
    let model = SettingsModel(store: settings, defaults: .standard, dictionary: dictionary)

    model.refreshDictionary()
    #expect(model.dictionaryMessage == "辞書ファイルはまだありません。", "無い辞書の文言")

    try Data("松尾\t末尾\n".utf8).write(to: dictionary.url)
    model.refreshDictionary()
    #expect(model.dictionaryMessage == "1件を読み込みました。", "読み込めた辞書の文言")

    try Data("松尾\t末尾\n壊れた行\n".utf8).write(to: dictionary.url)
    model.refreshDictionary()
    #expect(model.dictionaryMessage.hasPrefix("1件を読み込みました。2行目を読み込めませんでした。"),
      "壊れた行の文言: \(model.dictionaryMessage)")

    // 全行がタブ無しの回（空白で書いた回）は行番号を並べ切らない。
    try Data(Array(repeating: "松尾 末尾", count: 8).joined(separator: "\n").utf8)
      .write(to: dictionary.url)
    model.refreshDictionary()
    #expect(model.dictionaryMessage.contains("1・2・3・4・5行目ほか"), "行番号の打ち切り")

    expectNoVisibleWindows()
  }
}

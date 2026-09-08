// settings.json の読み書きと、編集モデル・起動・コントローラへの届き方。
// 4 つの検査はそれぞれ自分の一時ディレクトリを使い、同じ順番の状態遷移をその中で辿る。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Settings: 保存と編集")
struct SettingsStoreTests {
  /// 保存先だけを持つ使い捨ての設定。呼び出し側が root を消す。
  private func fixture() -> (root: URL, store: SettingsStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-settings-tests-\(UUID().uuidString)")
    return (root, SettingsStore(url: root.appendingPathComponent("settings.json")))
  }

  @Test("保存先は非公開で、壊れた内容や別スキーマを書き潰さない")
  func settingsStoreChecks() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }

    // read missing settings does not create files
    #expect(try store.load() == HotkeySettings(), "missing read")
    #expect(!FileManager.default.fileExists(atPath: root.path), "read wrote files")

    // save round trip is private and preserves launch independent preferences
    let saved = HotkeySettings(
      toggleKey: "opt+space", paletteKey: "ctrl+j", autoEnterEnabled: true,
      autoEnterUnverified: true)
    var savedWithVoiceProcessing = saved
    savedWithVoiceProcessing.voiceProcessingEnabled = true
    try store.save(savedWithVoiceProcessing)
    #expect(try store.load() == savedWithVoiceProcessing, "round trip")
    let mode =
      try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.intValue == 0o600, "settings permissions")

    // invalid settings cannot replace a valid file
    let before = try Data(contentsOf: store.url)
    #expect(throws: (any Error).self) { try store.save(HotkeySettings(toggleKey: "a")) }
    #expect(try Data(contentsOf: store.url) == before, "invalid save overwrote file")

    // unknown version is preserved and rejected
    let future = Data("{\"schema_version\":99,\"toggle_key\":\"opt+space\"}".utf8)
    try future.write(to: store.url)
    #expect(throws: (any Error).self) { _ = try store.load() }
    #expect(try Data(contentsOf: store.url) == future, "unknown version rewritten")

    // keys a newer vox may add are ignored, which is why schema_version stays 1
    #expect(
      try store.decode(Data("{\"schema_version\":1,\"auto_enter_future\":true}".utf8))
        == HotkeySettings(), "an unknown key was not ignored")

    // malformed settings are preserved
    let broken = Data("not-json".utf8)
    try broken.write(to: store.url)
    #expect(throws: (any Error).self) { _ = try store.load() }
    #expect(try Data(contentsOf: store.url) == broken, "broken file rewritten")

    // missing schema is preserved and cannot be overwritten by the model
    let missingSchema = Data("{\"auto_enter_enabled\":true}".utf8)
    try missingSchema.write(to: store.url)
    let model = SettingsModel(store: store, defaults: .standard)
    model.autoEnterEnabled = false
    #expect(model.loadFailed && !model.save(), "missing schema was accepted")
    #expect(try Data(contentsOf: store.url) == missingSchema, "missing schema file changed")

    // symlink settings are not followed
    let linked = SettingsStore(url: root.appendingPathComponent("linked.json"))
    try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: store.url)
    #expect(throws: (any Error).self) { _ = try linked.load() }
    #expect(throws: (any Error).self) { try linked.save(HotkeySettings()) }
  }

  @Test("壊れた設定のエラー文はファイルの場所と直し方を示す")
  func loadFailureNamesTheFile() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: store.url)

    let model = SettingsModel(store: store, defaults: .standard)

    #expect(model.loadFailed, "壊れた設定を読み込めたことにした")
    let message = model.errorMessage ?? ""
    #expect(message.contains(store.url.path), "エラー文にファイルの場所が無い: \(message)")
    #expect(message.contains("退避"), "エラー文に直し方が無い: \(message)")
  }

  @Test("編集モデルは保存するまで書かず、他のウィンドウの保存を踏まない")
  func settingsModelChecks() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save(HotkeySettings())

    // editing draft has no effect until saved
    let draft = SettingsModel(store: store, defaults: .standard)
    draft.toggleKey = "opt+space"
    draft.autoEnterEnabled = true
    draft.autoEnterUnverified = true
    draft.voiceProcessingEnabled = true
    #expect(try store.load().toggleKey == nil, "draft saved early")
    #expect(try !store.load().autoEnterEnabled, "auto Enter draft saved early")
    #expect(try store.load().autoEnterUnverified == false, "unverified auto Enter draft saved early")
    #expect(try !store.load().voiceProcessingEnabled, "voice processing draft saved early")
    #expect(draft.save(), "save failed")
    #expect(try store.load().toggleKey == "opt+space", "draft not saved")
    #expect(try store.load().autoEnterEnabled, "auto Enter draft not saved")
    #expect(try store.load().autoEnterUnverified, "unverified auto Enter draft not saved")
    #expect(try store.load().voiceProcessingEnabled, "voice processing draft not saved")

    // model does not report success after write failure
    let blocked = SettingsModel(
      store: SettingsStore(url: store.url.appendingPathComponent("settings.json")),
      defaults: .standard)
    blocked.toggleKey = "opt+space"
    #expect(!blocked.save() && blocked.errorMessage != nil, "failed write reported success")

    // cancel and reset do not write until save
    let editor = SettingsModel(store: store, defaults: .standard)
    editor.resetDraft()
    #expect(try store.load().toggleKey == "opt+space", "reset wrote immediately")
    #expect(try store.load().autoEnterEnabled, "reset wrote auto Enter immediately")
    #expect(try store.load().autoEnterUnverified, "reset wrote unverified auto Enter immediately")
    #expect(try store.load().voiceProcessingEnabled, "reset wrote voice processing immediately")
    editor.reload()
    #expect(editor.toggleKey == "opt+space", "reload did not discard draft")
    #expect(editor.autoEnterEnabled, "reload did not restore auto Enter")
    #expect(editor.autoEnterUnverified, "reload did not restore unverified auto Enter")
    #expect(editor.voiceProcessingEnabled, "reload did not restore voice processing")
    editor.resetDraft()
    #expect(editor.save(), "reset save failed")
    #expect(try store.load().toggleKey == nil, "reset persisted current launch default")
    #expect(try !store.load().autoEnterEnabled, "reset did not disable auto Enter")
    #expect(try store.load().autoEnterUnverified == false, "reset did not disable unverified auto Enter")
    #expect(try !store.load().voiceProcessingEnabled, "reset did not disable voice processing")

    // stale settings window cannot overwrite a newer save
    let first = SettingsModel(store: store, defaults: .standard)
    let second = SettingsModel(store: store, defaults: .standard)
    first.toggleKey = "opt+space"
    #expect(first.save(), "first save failed")
    second.paletteKey = "ctrl+j"
    #expect(!second.save(), "stale save accepted")
    #expect(try store.load().toggleKey == "opt+space", "newer choice lost")

    // CLI override is displayed as locked and is never persisted
    let overridden = SettingsModel(
      store: store, defaults: .standard, overrides: HotkeyOverrides(toggle: "ctrl+l"))
    overridden.toggleKey = "ctrl+l"
    overridden.paletteKey = "ctrl+j"
    #expect(overridden.save(), "independent key save failed")
    #expect(try store.load().toggleKey == "opt+space", "CLI override leaked into settings")
    #expect(try store.load().paletteKey == "ctrl+j", "unlocked key not saved")

    // load failure cannot silently replace a future schema through the model
    let future = Data("{\"schema_version\":99}".utf8)
    try future.write(to: store.url)
    let onFutureSchema = SettingsModel(store: store, defaults: .standard)
    onFutureSchema.resetDraft()
    #expect(onFutureSchema.loadFailed && !onFutureSchema.save(), "future schema was replaced")
    #expect(try Data(contentsOf: store.url) == future, "future schema changed")
    try store.save(HotkeySettings())

    // CLI override cannot hide a persisted conflict for the next launch
    let conflicting = SettingsModel(
      store: store, defaults: .standard,
      overrides: HotkeyOverrides(toggle: "opt+space"))
    conflicting.paletteKey = "cmd+shift+space"
    #expect(!conflicting.save(), "saved shortcuts prevent the next launch without the override")
    #expect(try store.load() == HotkeySettings(), "rejected save changed preferences")
  }

  @Test("起動は使える設定を組み立て、壊れた保存内容は残す")
  func settingsStartupChecks() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save(HotkeySettings())

    // startup recovers a saved conflict without overwriting preferences
    try store.save(HotkeySettings(paletteKey: "cmd+shift+space"))
    let before = try store.contents()
    let startup = try SettingsStartup(store: store, defaults: .standard)
    #expect(startup.configuration.toggle.spec == "cmd+shift+space", "fallback toggle changed")
    #expect(startup.configuration.palette.spec == "ctrl+p", "conflict was not recovered")
    #expect(startup.warning != nil, "recovery was silent")
    #expect(try store.contents() == before, "startup overwrote conflicting preferences")
    let model = SettingsModel(store: store, defaults: .standard)
    model.paletteKey = "ctrl+j"
    #expect(model.save(), "editor cannot repair the conflicting preference")

    // settings-only stays available when CLI keys conflict
    try store.save(HotkeySettings())
    let overrides = HotkeyOverrides(toggle: "ctrl+p")
    #expect(throws: (any Error).self) {
      _ = try SettingsStartup(store: store, defaults: .standard, overrides: overrides)
    }
    let editorStartup = try SettingsStartup(
      store: store, defaults: .standard,
      overrides: overrides, settingsOnly: true)
    #expect(editorStartup.warning != nil, "editor startup hid the configuration error")

    // CLI override can resolve a saved key conflict without losing the saved key
    try store.save(HotkeySettings(paletteKey: "cmd+shift+space"))
    let resolved = try SettingsStartup(
      store: store, defaults: .standard,
      overrides: HotkeyOverrides(toggle: "opt+space"))
    #expect(resolved.configuration.toggle.spec == "opt+space", "CLI override lost")
    #expect(
      resolved.configuration.palette.spec == "cmd+shift+space", "valid saved palette key discarded")
    #expect(resolved.warning == nil, "valid effective settings reported a conflict")

    // startup retains overrides and preserves malformed preferences
    let broken = Data("not-json".utf8)
    try broken.write(to: store.url)
    let onBroken = try SettingsStartup(
      store: store, defaults: .standard,
      overrides: HotkeyOverrides(toggle: "opt+space"))
    #expect(onBroken.configuration.toggle.spec == "opt+space", "fallback ignored the CLI key")
    #expect(
      try onBroken.warning != nil && store.contents() == broken, "broken preference was lost")
  }

  @Test("コントローラは録音が終わってから新しい設定を配る")
  func settingsControllerChecks() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try store.save(HotkeySettings())

    // controller applies persisted keys after the recording session ends
    let controller = SettingsController(store: store, defaults: .standard, configuration: .standard)
    var delivered: [HotkeyConfiguration] = []
    controller.onConfigurationChange = { delivered.append($0) }
    controller.beginSession()
    try store.save(HotkeySettings(toggleKey: "opt+space", paletteKey: "ctrl+j"))
    controller.reload()
    #expect(
      controller.activeConfiguration.toggle.spec == "cmd+shift+space",
      "finish key changed mid-session")
    controller.endSession()
    #expect(
      controller.activeConfiguration.toggle.spec == "opt+space", "pending key was not applied")
    #expect(
      delivered.last?.palette.spec == "ctrl+j", "updated keys did not reach the monitor callback")

    // controller loads auto Enter and preserves it across invalid reload
    try store.save(HotkeySettings(
      autoEnterEnabled: true, autoEnterUnverified: true, voiceProcessingEnabled: true))
    let loaded = SettingsController(store: store, defaults: .standard, configuration: .standard)
    #expect(loaded.autoEnterEnabled, "saved auto Enter was not loaded")
    #expect(loaded.autoEnterUnverified, "saved unverified auto Enter was not loaded")
    #expect(loaded.voiceProcessingEnabled, "saved voice processing was not loaded")
    try Data("not-json".utf8).write(to: store.url)
    loaded.reload()
    #expect(loaded.autoEnterEnabled, "invalid reload changed auto Enter")
    #expect(loaded.autoEnterUnverified, "invalid reload changed unverified auto Enter")
    #expect(loaded.voiceProcessingEnabled, "invalid reload changed voice processing")
    try store.save(HotkeySettings())
    loaded.reload()
    #expect(!loaded.autoEnterEnabled, "disabled auto Enter was not reloaded")
    #expect(loaded.autoEnterUnverified == false, "unverified auto Enter was not reloaded")
    #expect(!loaded.voiceProcessingEnabled, "disabled voice processing was not reloaded")

    // controller keeps usable keys when a reload fails
    let onBroken = SettingsController(store: store, defaults: .standard, configuration: .standard)
    try Data("not-json".utf8).write(to: store.url)
    onBroken.reload()
    #expect(
      onBroken.activeConfiguration == .standard, "invalid reload replaced working shortcuts")
  }
}

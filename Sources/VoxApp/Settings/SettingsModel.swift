import AppKit
import Combine
import Foundation
import VoxCore

@MainActor
public final class SettingsModel: ObservableObject {
  @Published public var toggleKey = ""
  @Published public var paletteKey = ""
  @Published public var autoEnterEnabled = false
  @Published public var autoEnterUnverified = false
  @Published public var voiceProcessingEnabled = false
  @Published public var microphoneInput: MicrophoneInput = .automatic
  @Published public var errorMessage: String?
  @Published public var savedMessage: String?
  @Published public private(set) var loadFailed = false
  @Published public private(set) var microphoneSnapshot: MicrophoneSnapshot = .unavailable
  @Published public private(set) var dictionaryMessage = ""
  public let defaults: HotkeyConfiguration
  public let overrides: HotkeyOverrides
  public var onSaved: (() -> Void)?
  private let store: SettingsStore
  private let dictionary: DictionaryStore
  private let microphoneProvider: () -> MicrophoneSnapshot
  private var loadedData: Data?
  private var original = HotkeySettings()
  private var resetting = false

  public init(
    store: SettingsStore, defaults: HotkeyConfiguration, overrides: HotkeyOverrides = .init(),
    dictionary: DictionaryStore = .standard,
    microphoneProvider: @escaping () -> MicrophoneSnapshot = { .unavailable }
  ) {
    self.store = store
    self.defaults = defaults
    self.overrides = overrides
    self.dictionary = dictionary
    self.microphoneProvider = microphoneProvider
    reload()
  }

  public func refreshMicrophones() {
    microphoneSnapshot = microphoneProvider()
  }

  /// 辞書は設定画面で編集しないので、件数と直すべき行番号だけを出す（ADR-019）。
  public func refreshDictionary() {
    do {
      guard let contents = try dictionary.contents() else {
        dictionaryMessage = "辞書ファイルはまだありません。"
        return
      }
      let table = DictionaryTable(contents: contents)
      dictionaryMessage = "\(table.entries.count)件を読み込みました。"
        + skippedNotice(table.skippedLines)
    } catch {
      dictionaryMessage = "辞書ファイルを読み込めません。ファイルを確認してから「更新」を押してください。"
    }
  }

  /// why: タブの代わりに空白で書いた回は落ちる行が全行になるので、先頭だけ挙げる。
  private func skippedNotice(_ lines: [Int]) -> String {
    guard !lines.isEmpty else { return "" }
    let shown = lines.prefix(5).map(String.init).joined(separator: "・")
    let rest = lines.count > 5 ? "ほか" : ""
    return "\(shown)行目\(rest)を読み込めませんでした。"
      + "1行に「置き換える表記」とタブ、「入れたい表記」を書いてください。"
  }

  /// 無ければ書き方を書いたファイルを作ってから、利用者が使っているエディタに渡す。
  public func openDictionaryFile() {
    do {
      try dictionary.createIfMissing()
    } catch {
      dictionaryMessage = "辞書ファイルを作れません。保存先を確認してください。"
      return
    }
    NSWorkspace.shared.open(dictionary.url)
    refreshDictionary()
  }

  public func reload() {
    savedMessage = nil
    errorMessage = nil
    resetting = false
    do {
      loadedData = try store.contents()
      original = try store.decode(loadedData)
      loadFailed = false
    } catch {
      original = HotkeySettings()
      loadFailed = true
      // 設定画面からは直せないので、どのファイルをどうすれば直るかまで出す。
      errorMessage = """
        \(error.localizedDescription)
        \(store.url.path)
        このファイルを別名に退避してから「再読み込み」してください。
        """
    }
    toggleKey = original.toggleKey ?? defaults.toggle.spec
    paletteKey = original.paletteKey ?? defaults.palette.spec
    autoEnterEnabled = original.autoEnterEnabled
    autoEnterUnverified = original.autoEnterUnverified
    voiceProcessingEnabled = original.voiceProcessingEnabled
    microphoneInput = original.microphoneInput
  }

  public func resetDraft() {
    toggleKey = defaults.toggle.spec
    paletteKey = defaults.palette.spec
    autoEnterEnabled = false
    autoEnterUnverified = false
    voiceProcessingEnabled = false
    microphoneInput = .automatic
    resetting = true
    savedMessage = nil
  }

  @discardableResult
  public func save() -> Bool {
    guard !loadFailed else { return false }
    do {
      guard try store.contents() == loadedData else { throw HotkeySettingsError.changedOnDisk }
      var settings = HotkeySettings(
        toggleKey: resetting && toggleKey == defaults.toggle.spec ? nil : toggleKey,
        paletteKey: resetting && paletteKey == defaults.palette.spec ? nil : paletteKey,
        autoEnterEnabled: autoEnterEnabled,
        autoEnterUnverified: autoEnterUnverified,
        voiceProcessingEnabled: voiceProcessingEnabled, microphoneInput: microphoneInput)
      // A CLI override is not editable here and must never become a persisted preference.
      if overrides.toggle != nil { settings.toggleKey = original.toggleKey }
      if overrides.palette != nil { settings.paletteKey = original.paletteKey }
      // Preferences must also work on the next launch without temporary CLI overrides.
      _ = try settings.resolved(defaults: defaults)
      _ = try settings.resolved(defaults: defaults, overrides: overrides)
      try store.save(settings)
      reload()
      savedMessage = "保存しました。次の録音から反映されます。"
      onSaved?()
      return true
    } catch {
      errorMessage = error.localizedDescription
      savedMessage = nil
      return false
    }
  }
}

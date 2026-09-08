import Foundation

public enum HotkeySettingsError: Error, LocalizedError {
  case invalidShortcut(String)
  case modifierRequired
  case duplicateShortcuts
  case unsupportedVersion
  case unreadableFile
  case changedOnDisk

  public var errorDescription: String? {
    switch self {
    case .invalidShortcut(let value): "ショートカット「\(value)」を認識できません。"
    case .modifierRequired: "⌘・⌃・⌥のいずれかと組み合わせてください。F1〜F12は単独でも使えます。"
    case .duplicateShortcuts: "録音とファイル検索に同じキーは使えません。別のキーにしてください。"
    case .unsupportedVersion: "新しい形式の設定ファイルです。新しいバージョンのvoxで開いてください。"
    case .unreadableFile: "設定ファイルを読み込めません。ファイルを確認してから再読み込みしてください。"
    case .changedOnDisk: "設定がほかの画面で変更されました。「再読み込み」してから保存してください。"
    }
  }
}

public struct HotkeyConfiguration: Equatable, Sendable {
  public let toggle: HotkeyBinding
  public let palette: HotkeyBinding
  public static let standard = Self(toggle: .commandShiftSpace, palette: .controlP)
}

public struct HotkeyOverrides: Sendable {
  public var toggle: String?
  public var palette: String?

  public init(toggle: String? = nil, palette: String? = nil) {
    self.toggle = toggle
    self.palette = palette
  }
}

public struct HotkeySettings: Codable, Equatable, Sendable {
  public var schemaVersion: Int = 1
  public var toggleKey: String?
  public var paletteKey: String?
  public var autoEnterEnabled: Bool
  public var autoEnterUnverified: Bool
  public var voiceProcessingEnabled: Bool

  public init(
    toggleKey: String? = nil, paletteKey: String? = nil,
    autoEnterEnabled: Bool = false, autoEnterUnverified: Bool = false,
    voiceProcessingEnabled: Bool = false
  ) {
    self.toggleKey = toggleKey
    self.paletteKey = paletteKey
    self.autoEnterEnabled = autoEnterEnabled
    self.autoEnterUnverified = autoEnterUnverified
    self.voiceProcessingEnabled = voiceProcessingEnabled
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case toggleKey = "toggle_key"
    case paletteKey = "palette_key"
    case autoEnterEnabled = "auto_enter_enabled"
    case autoEnterUnverified = "auto_enter_unverified"
    case voiceProcessingEnabled = "voice_processing_enabled"
  }

  /// 方式の設定は廃止した。`after_paste` を選んでいた意図は「確認できなくても送る」なので、
  /// 読むだけ引き継いで書き戻さない。壊れた値は移行せず既定に落とす。
  private enum LegacyKeys: String, CodingKey {
    case autoEnterMode = "auto_enter_mode"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    toggleKey = try container.decodeIfPresent(String.self, forKey: .toggleKey)
    paletteKey = try container.decodeIfPresent(String.self, forKey: .paletteKey)
    autoEnterEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoEnterEnabled) ?? false
    let legacy = try decoder.container(keyedBy: LegacyKeys.self)
    let migrated = (try? legacy.decodeIfPresent(String.self, forKey: .autoEnterMode)) == "after_paste"
    autoEnterUnverified =
      try container.decodeIfPresent(Bool.self, forKey: .autoEnterUnverified) ?? migrated
    voiceProcessingEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceProcessingEnabled) ?? false
  }

  public func validate() throws {
    guard schemaVersion == 1 else { throw HotkeySettingsError.unsupportedVersion }
    for value in [toggleKey, paletteKey].compactMap({ $0 }) {
      try HotkeyBinding.parse(value).validateForSettings()
    }
    if let toggleKey, let paletteKey,
      try HotkeyBinding.parse(toggleKey) == HotkeyBinding.parse(paletteKey) {
      throw HotkeySettingsError.duplicateShortcuts
    }
  }

  public func resolved(
    defaults: HotkeyConfiguration, overrides: HotkeyOverrides = .init()
  ) throws -> HotkeyConfiguration {
    try validate()
    let toggle = try HotkeyBinding.parse(overrides.toggle ?? toggleKey ?? defaults.toggle.spec)
    let palette = try HotkeyBinding.parse(overrides.palette ?? paletteKey ?? defaults.palette.spec)
    // 起動引数の指定も設定画面と同じ規則で弾く（`--toggle-key a` で全アプリの `a` を飲まない）。
    try toggle.validateForSettings()
    try palette.validateForSettings()
    guard toggle != palette else { throw HotkeySettingsError.duplicateShortcuts }
    return HotkeyConfiguration(toggle: toggle, palette: palette)
  }
}

/// The active recording keeps its original finish key until it has closed.
public struct HotkeyRuntime: Sendable {
  public private(set) var active: HotkeyConfiguration
  private var pending: HotkeyConfiguration?
  private var sessionActive = false
  public var hasPendingChange: Bool { pending != nil }

  public init(configuration: HotkeyConfiguration) { active = configuration }
  public mutating func beginSession() { sessionActive = true }

  public mutating func update(_ configuration: HotkeyConfiguration) {
    if sessionActive {
      pending = configuration == active ? nil : configuration
    } else {
      active = configuration
      pending = nil
    }
  }

  public mutating func endSession() {
    sessionActive = false
    if let pending { active = pending }
    pending = nil
  }
}

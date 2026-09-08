import Foundation
import VoxCore

/// Resolves startup preferences without opening windows or requesting permissions.
public struct SettingsStartup {
  public let configuration: HotkeyConfiguration
  public let warning: String?

  public init(
    store: SettingsStore, defaults: HotkeyConfiguration,
    overrides: HotkeyOverrides = .init(), settingsOnly: Bool = false
  ) throws {
    var saved: HotkeySettings
    var warning: String?
    do {
      saved = try store.load()
    } catch {
      warning = error.localizedDescription + " 初期設定で起動します。"
      saved = HotkeySettings()
    }
    do {
      configuration = try saved.resolved(defaults: defaults, overrides: overrides)
    } catch {
      if settingsOnly {
        // The editor must remain reachable to repair preferences/CLI conflicts.
        configuration = defaults
        warning = error.localizedDescription + " 設定または起動引数を確認してください。"
      } else if (try? saved.resolved(defaults: defaults)) == nil {
        // Recover a saved/default collision only after applying CLI precedence.
        configuration = try HotkeySettings().resolved(defaults: defaults, overrides: overrides)
        warning = error.localizedDescription + " 初期設定で起動します。"
      } else {
        // A conflict introduced by an explicit CLI override is a usage error.
        throw error
      }
    }
    self.warning = warning
  }
}

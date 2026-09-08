// ショートカットの表記・復号・優先順位。保存先には触らない。

import Foundation
import Testing
import VoxCore

@Suite("Settings: ショートカットの表記と優先順位")
struct HotkeyTests {
  @Test("shortcut aliases compare by physical key")
  func shortcutAliasesCompareByPhysicalKey() throws {
    #expect(
      try HotkeyBinding.parse("control+ENTER") == HotkeyBinding.parse("ctrl+return"),
      "alias mismatch")
    #expect(try HotkeyBinding.parse("shift+option+k").spec == "opt+shift+k", "normalization")
  }

  @Test("invalid shortcut syntax rejected")
  func invalidShortcutSyntaxRejected() {
    for value in ["", "ctrl++k", "ctrl+unknown", "hyper+k"] {
      #expect(throws: (any Error).self, "\(value) を受理した") {
        _ = try HotkeyBinding.parse(value)
      }
    }
  }

  @Test("settings reject plain typing and duplicate hotkeys")
  func settingsRejectPlainTypingAndDuplicateHotkeys() {
    #expect(throws: (any Error).self) {
      _ = try HotkeySettings(toggleKey: "k", paletteKey: "ctrl+p").resolved(defaults: .standard)
    }
    #expect(throws: (any Error).self) {
      _ = try HotkeySettings(toggleKey: "ctrl+return", paletteKey: "control+enter").resolved(
        defaults: .standard)
    }
    #expect(throws: (any Error).self) {
      _ = try HotkeySettings(toggleKey: "esc", paletteKey: "ctrl+p").resolved(defaults: .standard)
    }
  }

  @Test("function key can be used without a modifier")
  func functionKeyCanBeUsedWithoutAModifier() throws {
    let config = try HotkeySettings(toggleKey: "f8").resolved(defaults: .standard)
    #expect(config.toggle.keyCode == 100, "function key rejected")
  }

  @Test("missing preferences fall back to the standard shortcuts")
  func missingPreferencesFallBackToTheStandardShortcuts() throws {
    let saved = HotkeySettings()
    #expect(!saved.autoEnterEnabled, "auto Enter default changed")
    #expect(!saved.autoEnterUnverified, "unverified auto Enter default changed")
    #expect(!saved.voiceProcessingEnabled, "voice processing default changed")
    #expect(
      try saved.resolved(defaults: .standard).toggle.spec == "cmd+shift+space",
      "toggle default changed")
    #expect(
      try saved.resolved(defaults: .standard).palette.spec == "ctrl+p", "palette default changed")
  }

  @Test("voice processing decodes missing as off and rejects non-boolean values")
  func voiceProcessingDecodesMissingAsOff() throws {
    let legacy = try JSONDecoder().decode(
      HotkeySettings.self, from: Data("{\"schema_version\":1}".utf8))
    #expect(!legacy.voiceProcessingEnabled, "legacy settings enabled voice processing")
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(
        HotkeySettings.self,
        from: Data("{\"schema_version\":1,\"voice_processing_enabled\":\"true\"}".utf8))
    }
  }

  @Test("voice processing enabled and disabled round trip")
  func voiceProcessingRoundTrips() throws {
    for enabled in [false, true] {
      let settings = HotkeySettings(voiceProcessingEnabled: enabled)
      let decoded = try JSONDecoder().decode(
        HotkeySettings.self, from: JSONEncoder().encode(settings))
      #expect(decoded.voiceProcessingEnabled == enabled, "voice processing choice changed")
    }
  }

  @Test("auto Enter decodes missing as off and rejects non-boolean values")
  func autoEnterDecodesMissingAsOff() throws {
    let legacy = try JSONDecoder().decode(
      HotkeySettings.self, from: Data("{\"schema_version\":1}".utf8))
    #expect(!legacy.autoEnterEnabled, "legacy settings enabled auto Enter")
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(
        HotkeySettings.self,
        from: Data("{\"schema_version\":1,\"auto_enter_enabled\":\"true\"}".utf8))
    }
  }

  @Test("legacy auto Enter enabled sends nothing it cannot verify")
  func legacyAutoEnterKeepsVerifiedBehaviour() throws {
    let legacy = try JSONDecoder().decode(
      HotkeySettings.self,
      from: Data("{\"schema_version\":1,\"auto_enter_enabled\":true}".utf8))
    #expect(legacy.autoEnterEnabled, "legacy auto Enter setting was lost")
    #expect(!legacy.autoEnterUnverified, "legacy settings sent Enter it could not verify")
  }

  @Test("the legacy auto Enter mode is read once and never written back")
  func legacyAutoEnterModeMigrates() throws {
    let migrated = try JSONDecoder().decode(
      HotkeySettings.self,
      from: Data(
        "{\"schema_version\":1,\"auto_enter_enabled\":true,\"auto_enter_mode\":\"after_paste\"}"
          .utf8))
    #expect(migrated.autoEnterUnverified, "the terminal mode did not become the unverified setting")
    let json = String(bytes: try JSONEncoder().encode(migrated), encoding: .utf8) ?? ""
    #expect(!json.contains("auto_enter_mode"), "saving wrote the legacy mode back: \(json)")
    #expect(json.contains("auto_enter_unverified"), "the unverified setting was not saved: \(json)")
    for json in [
      "{\"schema_version\":1,\"auto_enter_mode\":\"verified\"}",
      "{\"schema_version\":1,\"auto_enter_mode\":\"unknown\"}",
      "{\"schema_version\":1,\"auto_enter_mode\":true}"
    ] {
      let decoded = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
      #expect(!decoded.autoEnterUnverified, "\(json) enabled the unverified setting")
    }
  }

  @Test("schema version remains required")
  func schemaVersionRemainsRequired() {
    for json in ["{}", "{\"schema_version\":null}"] {
      #expect(throws: (any Error).self, "\(json) を受理した") {
        _ = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
      }
    }
  }

  @Test("saved preferences win over the standard defaults")
  func savedPreferencesWinOverTheDefaults() throws {
    let config = try HotkeySettings(toggleKey: "opt+space").resolved(defaults: .standard)
    #expect(config.toggle.spec == "opt+space" && config.palette.spec == "ctrl+p", "saved ignored")
  }

  @Test("explicit overrides win without mutating saved settings")
  func explicitOverridesWinWithoutMutatingSavedSettings() throws {
    let saved = HotkeySettings(
      toggleKey: "opt+space", paletteKey: "ctrl+j",
      autoEnterEnabled: true)
    let config = try saved.resolved(
      defaults: .standard, overrides: HotkeyOverrides(toggle: "ctrl+l"))
    #expect(config.toggle.spec == "ctrl+l" && config.palette.spec == "ctrl+j", "precedence")
    #expect(saved.toggleKey == "opt+space", "override persisted")
  }

  @Test("effective conflict with explicit override is rejected")
  func effectiveConflictWithOverrideIsRejected() {
    #expect(throws: (any Error).self) {
      _ = try HotkeySettings(paletteKey: "ctrl+j").resolved(
        defaults: .standard, overrides: HotkeyOverrides(toggle: "ctrl+j"))
    }
  }

  @Test("explicit override is held to the same rule as the saved settings")
  func explicitOverrideIsValidatedLikeSavedSettings() {
    for overrides in [HotkeyOverrides(toggle: "a"), HotkeyOverrides(palette: "shift+a")] {
      do {
        let config = try HotkeySettings().resolved(defaults: .standard, overrides: overrides)
        Issue.record("plain typing accepted from the command line: \(config.toggle.spec)")
      } catch HotkeySettingsError.modifierRequired {
      } catch {
        Issue.record("rejected for another reason: \(error)")
      }
    }
  }

  @Test("changes wait until recording ends")
  func changesWaitUntilRecordingEnds() throws {
    var runtime = HotkeyRuntime(configuration: .standard)
    runtime.beginSession()
    runtime.update(try HotkeySettings(toggleKey: "opt+space").resolved(defaults: .standard))
    #expect(
      runtime.active.toggle.spec == "cmd+shift+space" && runtime.hasPendingChange,
      "recording key changed")
    runtime.endSession()
    #expect(
      runtime.active.toggle.spec == "opt+space" && !runtime.hasPendingChange, "pending lost")
  }

  @Test("latest pending choice wins and returning to active clears pending")
  func latestPendingChoiceWins() throws {
    var runtime = HotkeyRuntime(configuration: .standard)
    runtime.beginSession()
    runtime.update(try HotkeySettings(toggleKey: "opt+space").resolved(defaults: .standard))
    runtime.update(.standard)
    #expect(!runtime.hasPendingChange, "stale pending change")
    runtime.endSession()
    #expect(runtime.active.toggle.spec == "cmd+shift+space", "reverted choice lost")
  }

  @Test("recorded key preserves modifiers and rejects ordinary typing")
  func recordedKeyPreservesModifiers() throws {
    let binding = try HotkeyBinding.recorded(
      keyCode: 49, command: false, shift: false, control: false, option: true)
    #expect(binding.spec == "opt+space", "wrong captured shortcut")
    #expect(throws: (any Error).self) {
      _ = try HotkeyBinding.recorded(
        keyCode: 40, command: false, shift: true, control: false, option: false)
    }
    #expect(throws: (any Error).self) {
      _ = try HotkeyBinding.recorded(
        keyCode: 999, command: true, shift: false, control: false, option: false)
    }
  }
}

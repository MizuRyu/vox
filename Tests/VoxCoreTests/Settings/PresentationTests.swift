// 設定ウィンドウの出し入れと、閉じたあとに焦点を返す先。ウィンドウもキー入力も使わない。

import Testing
import VoxCore

@Suite("Settings: 設定ウィンドウの遅延と焦点")
struct PresentationTests {
  @Test("settings presentation deferral and focus restoration")
  func settingsPresentationDeferralAndFocusRestoration() {
    var presentation = SettingsPresentationState()
    #expect(presentation.requestShow() == true, "idle settings request was suppressed")
    _ = presentation.transition(to: .recording)
    #expect(presentation.requestShow() == true, "recording settings request was suppressed")
    _ = presentation.transition(to: .finishing)
    #expect(presentation.requestShow() == false, "settings can steal focus during insertion")
    #expect(presentation.requestShow() == false, "repeated settings request bypassed deferral")
    #expect(
      presentation.transition(to: .finishing) == false,
      "settings reopened before insertion completed")
    #expect(presentation.transition(to: .idle) == true, "deferred settings request was lost")
    #expect(
      presentation.transition(to: .idle) == false, "deferred settings request was replayed twice")
  }

  @Test("settings presentation follows the recording lifecycle")
  func settingsPresentationFollowsTheRecordingLifecycle() {
    var presentation = SettingsPresentationState()
    _ = presentation.transition(to: .starting)
    #expect(
      presentation.focusAfterClosing(paletteOpen: false, textEntryEnabled: true) == .hud,
      "closing settings during startup does not restore the HUD")
    #expect(
      presentation.focusAfterClosing(paletteOpen: false, textEntryEnabled: false) == .none,
      "settings close violates no-edit-mode during startup")
    _ = presentation.transition(to: .recording)
    #expect(
      presentation.focusAfterClosing(paletteOpen: true, textEntryEnabled: true) == .palette,
      "closing settings sends palette search typing into the transcript")
    #expect(
      presentation.focusAfterClosing(paletteOpen: true, textEntryEnabled: false) == .palette,
      "no-edit-mode prevents restoring the interactive palette")
    #expect(
      presentation.focusAfterClosing(paletteOpen: false, textEntryEnabled: true) == .hud,
      "closing settings does not restore the recording HUD")
    #expect(
      presentation.focusAfterClosing(paletteOpen: false, textEntryEnabled: false) == .none,
      "settings close violates no-edit-mode during recording")
    _ = presentation.transition(to: .finishing)
    #expect(
      presentation.focusAfterClosing(paletteOpen: true, textEntryEnabled: true) == .none,
      "closing settings steals focus while finishing")
    _ = presentation.transition(to: .idle)
    #expect(
      presentation.focusAfterClosing(paletteOpen: false, textEntryEnabled: true) == .none,
      "closing idle settings focuses a hidden HUD")
  }
}

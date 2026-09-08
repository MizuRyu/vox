// 設定画面と常駐の間。保存された設定をホットキーと HUD に配り、閉じたあとの key window を戻す。

import Foundation
import VoxCore

@MainActor
final class SettingsCoordinator {
  private let controller: SettingsController
  private let hud: HudPanel
  private let hotkeys: HotkeyMonitor
  private let palette: PaletteCoordinator

  init(
    controller: SettingsController, hud: HudPanel, hotkeys: HotkeyMonitor,
    palette: PaletteCoordinator
  ) {
    self.controller = controller
    self.hud = hud
    self.hotkeys = hotkeys
    self.palette = palette
  }

  func connect() {
    controller.onConfigurationChange = { [weak self] configuration in
      guard let self else { return }
      VoxConfig.toggleChord = configuration.toggle
      VoxConfig.paletteChord = configuration.palette
      hotkeys.toggleChord = configuration.toggle
      hotkeys.paletteChord = configuration.palette
      hud.model.toggleShortcutLabel = configuration.toggle.label
    }
    controller.onClose = { [weak self] in
      guard let self else { return }
      switch controller.focusAfterClosing(
        paletteOpen: palette.isOpen, textEntryEnabled: VoxConfig.textEntryEnabled) {
      case .palette: palette.focus()
      case .hud: hud.makeKeyAgain()
      case .none: break
      }
    }
    hud.model.onSettings = { [weak self] in self?.controller.show() }
    hud.model.toggleShortcutLabel = controller.activeConfiguration.toggle.label
    // The settings window receives captured shortcuts before they can start/finish recording.
    hotkeys.isSuspended = { [weak self] in self?.controller.isKeyWindow == true }
  }

  var autoEnterEnabled: Bool { controller.autoEnterEnabled }
  var autoEnterUnverified: Bool { controller.autoEnterUnverified }
  var voiceProcessingEnabled: Bool { controller.voiceProcessingEnabled }

  func listen() { controller.listen() }
  func reload() { controller.reload() }
  func beginSession() { controller.beginSession() }
  func endSession() { controller.endSession() }
  func hide() { controller.hide() }
  func transition(to phase: SettingsPresentationState.Phase) { controller.transition(to: phase) }
}

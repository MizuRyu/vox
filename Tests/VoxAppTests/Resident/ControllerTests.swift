// 常駐コントローラの外から見える契約。coordinator に分けても変わってはいけないところだけを見る。
// マイクもイベントタップも開かないので、録音そのものには入らない。

import AppKit
import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Test("常駐コントローラは待機のまま設定変更を受け取り、二重の停止にも耐える")
func residentControllerChecks() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)

  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vox-controller-checks-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
  try store.save(HotkeySettings())
  let settings = SettingsController(
    store: store, defaults: .standard, configuration: .standard)
  let controller = VoxController(
    metrics: MetricsWriter(path: root.appendingPathComponent("metrics.jsonl").path),
    history: HistoryWriter(path: root.appendingPathComponent("history.jsonl").path),
    settings: settings)

  #expect(controller.residentPhase == .idle, "a fresh controller is not idle")
  #expect(!controller.performMenuPrimaryAction(), "idle menu action ran without a captured target")

  try controller.start(enableHotkeys: false)

  // 保存された設定は onConfigurationChange 経由でホットキーと HUD に配られる。
  try store.save(HotkeySettings(toggleKey: "ctrl+opt+k"))
  settings.reload()
  #expect(
    settings.activeConfiguration.toggle != HotkeyConfiguration.standard.toggle,
    "the saved shortcut was not loaded")
  #expect(
    VoxConfig.toggleChord == settings.activeConfiguration.toggle,
    "a saved shortcut change did not reach the running configuration")

  controller.disableHotkeysWhenIdle()
  #expect(controller.residentPhase == .idle, "disabling hotkeys while idle changed the phase")

  await controller.shutdown()
  #expect(controller.residentPhase == .idle, "the controller is not idle after shutdown")
  #expect(controller.recording == nil, "shutdown left a recording session behind")
  await controller.shutdown()
}

@MainActor
@Test("入力デバイスが変わったら、録音中は表示中の本文を挿入経路へ渡す")
func captureInterruptionHandsVisibleTextToTheInsertionPath() {
  #expect(
    VoxController.captureInterruptionOutcome(
      phase: .recording, head: "きょうは", tentative: "いい天気", tail: "メモ")
      == .insert("きょうはいい天気メモ"),
    "the visible text was not handed to the insertion path")
  #expect(
    VoxController.captureInterruptionOutcome(phase: .recording, head: "", tentative: "", tail: "")
      == .giveUp,
    "an empty screen did not give up")
  #expect(
    VoxController.captureInterruptionOutcome(
      phase: .starting, head: "", tentative: "", tail: "") == .abortStart,
    "a device change while starting did not abort the start")
  #expect(
    VoxController.captureInterruptionOutcome(
      phase: .finishing, head: "きょうは", tentative: "", tail: "") == .ignore,
    "a device change while finishing interrupted the running insertion")
  #expect(
    VoxController.captureInterruptionOutcome(phase: .idle, head: "", tentative: "", tail: "")
      == .ignore,
    "a device change while idle started a recording teardown")
}

@MainActor
@Test("録音 1 回分は開始時の設定を写し取り、後から設定が変わっても動かない")
func recordingSessionSnapshot() throws {
  NSApplication.shared.setActivationPolicy(.prohibited)

  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vox-recording-session-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
  try store.save(
    HotkeySettings(
      autoEnterEnabled: true, autoEnterUnverified: true, voiceProcessingEnabled: true))
  let settings = SettingsController(
    store: store, defaults: .standard, configuration: .standard)
  let hud = HudPanel()
  let coordinator = SettingsCoordinator(
    controller: settings, hud: hud, hotkeys: HotkeyMonitor(),
    palette: PaletteCoordinator(hud: hud))

  let recording = RecordingSession(
    toggleOnMilliseconds: 1_000, settings: coordinator, target: nil)
  #expect(recording.autoEnterEnabled, "auto enter was not taken from the settings")
  #expect(recording.autoEnterUnverified, "unverified auto Enter was not taken from the settings")
  #expect(recording.voiceProcessingEnabled, "voice processing was not taken from the settings")
  #expect(recording.metrics?.toggleOnMilliseconds == 1_000, "the toggle time was not recorded")
  #expect(recording.injectionTarget == nil, "a session without a target app captured one")

  // 録音中に設定を変えても、この回の挿入には効かない。
  try store.save(HotkeySettings())
  settings.reload()
  #expect(
    recording.autoEnterEnabled && recording.autoEnterUnverified
      && recording.voiceProcessingEnabled,
    "a settings change during the recording reached the running session")
}

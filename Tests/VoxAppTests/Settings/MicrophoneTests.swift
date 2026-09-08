// マイク一覧の取り出しと、設定ウィンドウの下書き・保存先から切り離されていること。

import CoreAudio
import Foundation
import Testing
@testable import VoxApp
import VoxCore

private enum SyntheticFailure: Error { case failed }

private struct SyntheticMicrophoneProvider: MicrophoneDeviceProviding {
  var ids: Result<[UInt32], Error>
  var defaultID: Result<UInt32?, Error> = .success(nil)
  var states: [UInt32: Result<MicrophoneDeviceState?, Error>] = [:]

  func deviceIDs() throws -> [UInt32] { try ids.get() }
  func defaultInputDeviceID() throws -> UInt32? { try defaultID.get() }
  func state(for id: UInt32) throws -> MicrophoneDeviceState? {
    try states[id, default: .success(nil)].get()
  }
}

@Suite("Settings: マイクの一覧")
struct MicrophoneTests {
  @Test("microphone device snapshot filters and reports provider states")
  func microphoneDeviceSnapshot() {
    let normal = SyntheticMicrophoneProvider(
      ids: .success([11, 22, 33]),
      defaultID: .success(22),
      states: [
        11: .success(.init(isAlive: true, hasInputStreams: true, name: "Synthetic Alpha")),
        22: .success(.init(isAlive: true, hasInputStreams: true, name: "Synthetic Beta")),
        33: .success(.init(isAlive: true, hasInputStreams: false, name: "Synthetic Output"))
      ])
    #expect(
      MicrophoneDevices.snapshot(using: normal) == .available(
        devices: [
          .init(id: 11, name: "Synthetic Alpha"),
          .init(id: 22, name: "Synthetic Beta")
        ], defaultDeviceID: 22),
      "input device snapshot mismatch")

    let empty = SyntheticMicrophoneProvider(ids: .success([]))
    #expect(
      MicrophoneDevices.snapshot(using: empty) == .available(devices: [], defaultDeviceID: nil),
      "empty device list became unavailable")

    let missingDefault = SyntheticMicrophoneProvider(
      ids: .success([11]), defaultID: .failure(SyntheticFailure.failed),
      states: [11: .success(.init(isAlive: true, hasInputStreams: true, name: nil))])
    #expect(
      MicrophoneDevices.snapshot(using: missingDefault) == .available(
        devices: [.init(id: 11, name: "Microphone")], defaultDeviceID: nil),
      "unknown default or name fallback failed")

    let disappeared = SyntheticMicrophoneProvider(
      ids: .success([11, 22]),
      states: [
        11: .failure(SyntheticFailure.failed),
        22: .success(.init(isAlive: false, hasInputStreams: true, name: "Synthetic Gone"))
      ])
    #expect(
      MicrophoneDevices.snapshot(using: disappeared) == .available(
        devices: [], defaultDeviceID: nil),
      "disappeared or non-alive device was retained")

    let failed = SyntheticMicrophoneProvider(ids: .failure(SyntheticFailure.failed))
    #expect(
      MicrophoneDevices.snapshot(using: failed) == .unavailable,
      "enumeration failure was reported as available")
  }

  @Test("microphone snapshot carries the transport of each device")
  func microphoneSnapshotCarriesTransport() {
    let provider = SyntheticMicrophoneProvider(
      ids: .success([11, 22]),
      defaultID: .success(22),
      states: [
        11: .success(
          .init(
            isAlive: true, hasInputStreams: true, name: "Synthetic Built-in",
            transport: kAudioDeviceTransportTypeBuiltIn, uid: "synthetic-builtin")),
        22: .success(
          .init(
            isAlive: true, hasInputStreams: true, name: "Synthetic Headset",
            transport: kAudioDeviceTransportTypeBluetooth, uid: "synthetic-headset"))
      ])
    #expect(
      MicrophoneDevices.snapshot(using: provider) == .available(
        devices: [
          .init(id: 11, name: "Synthetic Built-in", transport: .builtIn),
          .init(id: 22, name: "Synthetic Headset", transport: .bluetooth)
        ], defaultDeviceID: 22),
      "the transport of each device was lost")
    #expect(
      MicrophoneDevices.defaultInputIdentity(using: provider)
        == MicrophoneIdentity(transport: .bluetooth, uid: "synthetic-headset"),
      "the default input identity used for the diagnostic log is wrong")

    let noDefault = SyntheticMicrophoneProvider(ids: .success([11]))
    #expect(
      MicrophoneDevices.defaultInputIdentity(using: noDefault) == nil,
      "an absent default input still produced an identity")
  }

  @MainActor
  @Test("microphone model refresh is isolated from settings drafts and storage")
  func microphoneModelRefresh() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("vox-microphone-model-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
    try store.save(HotkeySettings(toggleKey: "opt+space", paletteKey: "ctrl+j"))
    let before = try store.contents()

    var supplied: MicrophoneSnapshot = .available(
      devices: [MicrophoneDevice(id: 7, name: "合成マイク A")], defaultDeviceID: 7)
    var calls = 0
    let model = SettingsModel(store: store, defaults: .standard) {
      calls += 1
      return supplied
    }

    #expect(model.microphoneSnapshot == .unavailable, "provider ran during model initialization")
    #expect(calls == 0, "initial microphone query was not deferred")
    model.toggleKey = "cmd+shift+k"
    model.paletteKey = "ctrl+m"

    model.refreshMicrophones()
    #expect(
      model.microphoneSnapshot == supplied && calls == 1, "initial refresh did not use provider")
    #expect(
      model.toggleKey == "cmd+shift+k" && model.paletteKey == "ctrl+m",
      "refresh discarded hotkey draft")
    #expect(try store.contents() == before, "refresh wrote preferences")

    supplied = .available(
      devices: [MicrophoneDevice(id: 8, name: String(repeating: "長い合成マイク名", count: 20))],
      defaultDeviceID: nil)
    model.refreshMicrophones()
    #expect(
      model.microphoneSnapshot == supplied && calls == 2,
      "refresh did not replace disconnected devices")

    supplied = .available(devices: [], defaultDeviceID: nil)
    model.refreshMicrophones()
    #expect(model.microphoneSnapshot == supplied, "empty device state was lost")

    supplied = .unavailable
    model.refreshMicrophones()
    #expect(model.microphoneSnapshot == .unavailable, "unavailable state was lost")
    #expect(
      model.toggleKey == "cmd+shift+k" && model.paletteKey == "ctrl+m",
      "later refresh discarded draft")
    #expect(try store.contents() == before, "microphone state changes wrote preferences")
  }
}

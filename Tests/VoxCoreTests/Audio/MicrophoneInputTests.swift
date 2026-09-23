import Foundation
import Testing
@testable import VoxCore

@Suite("Audio: マイクの選択")
struct MicrophoneInputTests {
  private let builtIn = MicrophoneDevice(id: 1, name: "Synthetic Built-in", transport: .builtIn, uid: "built-in")
  private let headset = MicrophoneDevice(id: 2, name: "Synthetic Headset", transport: .bluetooth, uid: "headset")
  private let usb = MicrophoneDevice(id: 3, name: "Synthetic USB", transport: .usb, uid: "usb")

  @Test("自動はBluetooth出力が稼働しているときだけ内蔵入力を選ぶ")
  func automaticRouting() throws {
    for inputTransport in [AudioTransport.bluetooth, .bluetoothLowEnergy] {
      let input = MicrophoneDevice(id: 2, name: "Synthetic Headset", transport: inputTransport)
      for outputTransport in [AudioTransport.bluetooth, .bluetoothLowEnergy, .builtIn, .usb, .unknown] {
        for running in [false, true] {
          let selected = try MicrophoneInput.automatic.resolve(
            devices: [input, builtIn], defaultDeviceID: 2,
            output: .init(transport: outputTransport, isRunning: running))
          let shouldSwitch = running && [.bluetooth, .bluetoothLowEnergy].contains(outputTransport)
          #expect(selected.id == (shouldSwitch ? 1 : 2))
        }
      }
    }
  }

  @Test("自動は内蔵なしや出力不明なら既定を保ち、USB入力も変えない")
  func automaticPreservesOtherRoutes() throws {
    let playing = MicrophoneOutput(transport: .bluetooth, isRunning: true)
    #expect(try MicrophoneInput.automatic.resolve(devices: [headset], defaultDeviceID: 2, output: playing) == headset)
    #expect(try MicrophoneInput.automatic.resolve(devices: [headset, builtIn], defaultDeviceID: 2, output: nil) == headset)
    #expect(try MicrophoneInput.automatic.resolve(devices: [usb, builtIn], defaultDeviceID: 3, output: playing) == usb)
    #expect(throws: MicrophoneInputError.noInput) {
      try MicrophoneInput.automatic.resolve(devices: [builtIn], defaultDeviceID: nil, output: playing)
    }
  }

  @Test("明示指定とシステム既定は自動切替より優先し、消えた指定機器へは戻らない")
  func explicitSelection() throws {
    let devices = [builtIn, headset, usb]
    let playing = MicrophoneOutput(transport: .bluetooth, isRunning: true)
    #expect(try MicrophoneInput.systemDefault.resolve(devices: devices, defaultDeviceID: 2, output: playing) == headset)
    #expect(try MicrophoneInput.device("usb").resolve(devices: devices, defaultDeviceID: 2, output: playing) == usb)
    #expect(try MicrophoneInput.device("headset").resolve(devices: devices, defaultDeviceID: 1, output: nil) == headset)
    #expect(throws: MicrophoneInputError.deviceUnavailable) {
      try MicrophoneInput.device("missing").resolve(devices: devices, defaultDeviceID: 1, output: nil)
    }
  }

  @Test("UIDで保存した指定はAudioDeviceIDが変わっても解決できる")
  func persistentIdentity() throws {
    let reconnected = MicrophoneDevice(id: 99, name: "Synthetic USB", transport: .usb, uid: "usb")
    #expect(try MicrophoneInput.device("usb").resolve(devices: [reconnected], defaultDeviceID: nil, output: nil).id == 99)
  }

  @Test("旧設定は自動になり、全選択肢を往復し、不正な指定は拒否する")
  func settingsPersistence() throws {
    let legacy = try JSONDecoder().decode(HotkeySettings.self, from: Data(#"{"schema_version":1}"#.utf8))
    #expect(legacy.microphoneInput == .automatic)
    for selection in [MicrophoneInput.automatic, .systemDefault, .device("synthetic-uid")] {
      let saved = HotkeySettings(microphoneInput: selection)
      let decoded = try JSONDecoder().decode(HotkeySettings.self, from: JSONEncoder().encode(saved))
      #expect(decoded.microphoneInput == selection)
    }
    for value in [#"{"mode":"invalid"}"#, #"{"mode":"device"}"#, #"{"mode":"device","uid":""}"#] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(HotkeySettings.self, from: Data("{\"schema_version\":1,\"microphone_input\":\(value)}".utf8))
      }
    }
  }
}

import AVFoundation
import AudioToolbox
import Testing
@testable import VoxApp

private final class SyntheticInputUnit: AudioInputUnitAccess {
  var values: [AudioInputProperty: UInt32] = [
    .inputEnabled: 0, .outputEnabled: 1, .currentDevice: 10, .voiceProcessingDevice: 10
  ]
  var writes: [AudioInputProperty] = []
  var failWrites = false
  var ignoreWrites = false

  func read(_ property: AudioInputProperty) throws -> UInt32 { values[property] ?? 0 }

  func write(_ property: AudioInputProperty, value: UInt32) throws {
    writes.append(property)
    if failWrites { throw AudioInputConfigurationError.propertyFailed(-1) }
    if !ignoreWrites { values[property] = value }
  }
}

@Suite("Audio: 入力Audio Unitの構成")
struct InputConfigurationTests {
  @Test("入力専用AUHALは入力を有効、出力を無効にしてから機器を選び、一致していれば書き直さない")
  func inputOnly() throws {
    let unit = SyntheticInputUnit()
    try AudioInputConfiguration.prepare(unit, deviceID: 42, route: .inputOnly)
    #expect(unit.writes == [.inputEnabled, .outputEnabled, .currentDevice])
    unit.writes = []
    try AudioInputConfiguration.prepare(unit, deviceID: 42, route: .inputOnly)
    #expect(unit.writes.isEmpty)
    #expect(AudioInputProperty.inputEnabled.address.scope == kAudioUnitScope_Input)
    #expect(AudioInputProperty.outputEnabled.address.scope == kAudioUnitScope_Output)
  }

  @Test("通話向け処理は入力elementを選び、変更できないEnableIOには書かない")
  func voiceProcessing() throws {
    let unit = SyntheticInputUnit()
    try AudioInputConfiguration.prepare(unit, deviceID: 42, route: .voiceProcessing)
    #expect(unit.writes == [.voiceProcessingDevice])
    #expect(AudioInputProperty.currentDevice.address.element == 0)
    #expect(AudioInputProperty.voiceProcessingDevice.address.element == 1)
  }

  @Test("書込失敗と反映されない設定は録音開始エラーになる")
  func rejectedConfiguration() throws {
    let unit = SyntheticInputUnit()
    unit.failWrites = true
    #expect(throws: AudioInputConfigurationError.propertyFailed(-1)) {
      try AudioInputConfiguration.prepare(unit, deviceID: 42, route: .inputOnly)
    }
    unit.failWrites = false
    unit.ignoreWrites = true
    #expect(throws: AudioInputConfigurationError.configurationChanged) {
      try AudioInputConfiguration.prepare(unit, deviceID: 42, route: .inputOnly)
    }
  }

  @Test("開始後の入力先やIOの変化は検出し、動作中に書き戻さない")
  func changedAfterStart() throws {
    let cases: [(AudioInputRoute, AudioInputProperty)] = [
      (.inputOnly, .currentDevice), (.inputOnly, .inputEnabled), (.inputOnly, .outputEnabled),
      (.voiceProcessing, .voiceProcessingDevice)
    ]
    for (route, property) in cases {
      let unit = SyntheticInputUnit()
      try AudioInputConfiguration.prepare(unit, deviceID: 42, route: route)
      unit.writes = []
      unit.values[property] = 99
      #expect(throws: AudioInputConfigurationError.configurationChanged) {
        try AudioInputConfiguration.validate(unit, deviceID: 42, route: route)
      }
      #expect(unit.writes.isEmpty)
    }
  }

  @Test("AUHALから受け取る形式は機器のレートとチャンネル数のfloat32非インターリーブ")
  func clientFormat() throws {
    let format = try #require(HALInputCapture.clientFormat(sampleRate: 48_000, channels: 3))
    #expect(format.sampleRate == 48_000)
    #expect(format.channelCount == 3)
    #expect(format.commonFormat == .pcmFormatFloat32)
    #expect(!format.isInterleaved)
    #expect(HALInputCapture.clientFormat(sampleRate: 0, channels: 1) == nil)
    #expect(HALInputCapture.clientFormat(sampleRate: 48_000, channels: 0) == nil)
  }
}

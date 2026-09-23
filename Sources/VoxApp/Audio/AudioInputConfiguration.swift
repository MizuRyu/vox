import AudioToolbox
import Foundation

enum AudioInputProperty: Hashable {
  case inputEnabled, outputEnabled, currentDevice, voiceProcessingDevice

  var address: (id: AudioUnitPropertyID, scope: AudioUnitScope, element: AudioUnitElement) {
    switch self {
    case .inputEnabled: (kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1)
    case .outputEnabled: (kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0)
    case .currentDevice: (kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0)
    case .voiceProcessingDevice: (kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1)
    }
  }
}

/// 録音用 Audio Unit の経路。
enum AudioInputRoute {
  /// Vox が作る入力専用 AUHAL（ADR-016）。
  case inputOnly
  /// AVAudioEngine の VoiceProcessingIO。EnableIO は変更できず、入力機器は element 1。
  case voiceProcessing

  var deviceProperty: AudioInputProperty {
    self == .inputOnly ? .currentDevice : .voiceProcessingDevice
  }
}

protocol AudioInputUnitAccess {
  func read(_ property: AudioInputProperty) throws -> UInt32
  func write(_ property: AudioInputProperty, value: UInt32) throws
}

enum AudioInputConfigurationError: Error, Equatable, LocalizedError, CustomStringConvertible {
  case missingUnit
  case propertyFailed(OSStatus)
  case configurationChanged

  var description: String {
    switch self {
    case .missingUnit:
      "録音用のマイクを準備できませんでした。マイクの接続を確認してください。"
    case .propertyFailed(let status):
      "マイクの設定を適用・確認できませんでした。別のマイクを選んでください（\(status)）。"
    case .configurationChanged:
      "録音用の音声構成が変わりました。マイクを確認し、もう一度録音してください。"
    }
  }

  var errorDescription: String? { description }
}

struct CoreAudioInputUnit: AudioInputUnitAccess {
  let unit: AudioUnit

  init(_ unit: AudioUnit?) throws {
    guard let unit else { throw AudioInputConfigurationError.missingUnit }
    self.unit = unit
  }

  func read(_ property: AudioInputProperty) throws -> UInt32 {
    let address = property.address
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioUnitGetProperty(unit, address.id, address.scope, address.element, &value, &size)
    guard status == noErr else { throw AudioInputConfigurationError.propertyFailed(status) }
    guard size == MemoryLayout<UInt32>.size else {
      throw AudioInputConfigurationError.configurationChanged
    }
    return value
  }

  func write(_ property: AudioInputProperty, value: UInt32) throws {
    let address = property.address
    var value = value
    let status = AudioUnitSetProperty(
      unit, address.id, address.scope, address.element, &value, UInt32(MemoryLayout<UInt32>.size))
    guard status == noErr else { throw AudioInputConfigurationError.propertyFailed(status) }
  }
}

enum AudioInputConfiguration {
  static func prepare(_ unit: some AudioInputUnitAccess, deviceID: UInt32, route: AudioInputRoute) throws {
    // 初期化前の AUHAL に、入力有効・出力無効・機器の順で設定する（Chromium と同じ順序）。
    // AVAudioEngine が組み上げた Audio Unit の EnableIO を後から変えると構成変更が通知されるので、
    // この設定は Vox が自分で作った AUHAL にだけ行う。
    if route == .inputOnly {
      try setIfNeeded(unit, .inputEnabled, value: 1)
      try setIfNeeded(unit, .outputEnabled, value: 0)
    }
    try setIfNeeded(unit, route.deviceProperty, value: deviceID)
    try validate(unit, deviceID: deviceID, route: route)
  }

  static func validate(_ unit: some AudioInputUnitAccess, deviceID: UInt32, route: AudioInputRoute) throws {
    guard try unit.read(route.deviceProperty) == deviceID else {
      throw AudioInputConfigurationError.configurationChanged
    }
    guard route == .inputOnly else { return }
    guard try unit.read(.inputEnabled) == 1, try unit.read(.outputEnabled) == 0 else {
      throw AudioInputConfigurationError.configurationChanged
    }
  }

  private static func setIfNeeded(
    _ unit: some AudioInputUnitAccess, _ property: AudioInputProperty, value: UInt32
  ) throws {
    if try unit.read(property) != value { try unit.write(property, value: value) }
  }
}

import CoreAudio
import Foundation
import VoxCore

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
  public let id: UInt32
  public let name: String
  public let transport: AudioTransport

  public init(id: UInt32, name: String, transport: AudioTransport = .unknown) {
    self.id = id
    self.name = name
    self.transport = transport
  }
}

public enum MicrophoneSnapshot: Equatable, Sendable {
  case available(devices: [MicrophoneDevice], defaultDeviceID: UInt32?)
  case unavailable
}

/// 既定入力の素性。録音の診断ログ（`audio_input`）だけが使う。
struct MicrophoneIdentity: Equatable, Sendable {
  let transport: AudioTransport
  let uid: String?
}

struct MicrophoneDeviceState {
  let isAlive: Bool
  let hasInputStreams: Bool
  let name: String?
  var transport: UInt32 = 0
  var uid: String?
}

protocol MicrophoneDeviceProviding {
  func deviceIDs() throws -> [UInt32]
  func defaultInputDeviceID() throws -> UInt32?
  func state(for id: UInt32) throws -> MicrophoneDeviceState?
}

public enum MicrophoneDevices {
  public static func snapshot() -> MicrophoneSnapshot {
    snapshot(using: CoreAudioMicrophoneProvider())
  }

  static func snapshot(
    using provider: some MicrophoneDeviceProviding
  ) -> MicrophoneSnapshot {
    let ids: [UInt32]
    do { ids = try provider.deviceIDs() } catch { return .unavailable }

    let defaultID = (try? provider.defaultInputDeviceID()) ?? nil
    let devices = ids.compactMap { id -> MicrophoneDevice? in
      guard let state = try? provider.state(for: id),
        state.isAlive, state.hasInputStreams
      else { return nil }
      let trimmedName = state.name?.trimmingCharacters(in: .whitespacesAndNewlines)
      return MicrophoneDevice(
        id: id, name: trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Microphone",
        transport: AudioTransport(rawValue: state.transport))
    }
    return .available(devices: devices, defaultDeviceID: defaultID)
  }

  /// 録音開始時の診断ログ用。一覧と同じ取得経路を使う。
  static func defaultInputIdentity() -> MicrophoneIdentity? {
    defaultInputIdentity(using: CoreAudioMicrophoneProvider())
  }

  static func defaultInputIdentity(
    using provider: some MicrophoneDeviceProviding
  ) -> MicrophoneIdentity? {
    guard let id = (try? provider.defaultInputDeviceID()) ?? nil,
      let state = (try? provider.state(for: id)) ?? nil
    else { return nil }
    return MicrophoneIdentity(transport: AudioTransport(rawValue: state.transport), uid: state.uid)
  }
}

private enum CoreAudioReadError: Error { case failed, invalidSize }

private struct CoreAudioMicrophoneProvider: MicrophoneDeviceProviding {
  private static let system = AudioObjectID(kAudioObjectSystemObject)
  private static let maximumDeviceCount = 4_096

  func deviceIDs() throws -> [UInt32] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var byteCount: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &byteCount) == noErr,
      byteCount % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0
    else { throw CoreAudioReadError.invalidSize }
    let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
    guard count <= Self.maximumDeviceCount else { throw CoreAudioReadError.invalidSize }
    guard count > 0 else { return [] }

    var devices = [AudioDeviceID](repeating: 0, count: count)
    let result = devices.withUnsafeMutableBytes { bytes in
      AudioObjectGetPropertyData(Self.system, &address, 0, nil, &byteCount, bytes.baseAddress!)
    }
    guard result == noErr,
      byteCount == UInt32(count * MemoryLayout<AudioDeviceID>.stride)
    else { throw CoreAudioReadError.failed }
    return devices
  }

  func defaultInputDeviceID() throws -> UInt32? {
    let value: AudioDeviceID = try fixedValue(
      object: Self.system,
      selector: kAudioHardwarePropertyDefaultInputDevice,
      scope: kAudioObjectPropertyScopeGlobal)
    return value == kAudioObjectUnknown ? nil : value
  }

  func state(for id: UInt32) throws -> MicrophoneDeviceState? {
    let alive: UInt32 = try fixedValue(
      object: id, selector: kAudioDevicePropertyDeviceIsAlive,
      scope: kAudioObjectPropertyScopeGlobal)
    let inputStreamBytes = try propertySize(
      object: id, selector: kAudioDevicePropertyStreams,
      scope: kAudioDevicePropertyScopeInput)
    let name = try? stringValue(
      object: id, selector: kAudioObjectPropertyName,
      scope: kAudioObjectPropertyScopeGlobal)
    let transport: UInt32 = (try? fixedValue(
      object: id, selector: kAudioDevicePropertyTransportType,
      scope: kAudioObjectPropertyScopeGlobal)) ?? kAudioDeviceTransportTypeUnknown
    let uid = try? stringValue(
      object: id, selector: kAudioDevicePropertyDeviceUID,
      scope: kAudioObjectPropertyScopeGlobal)
    return MicrophoneDeviceState(
      isAlive: alive != 0, hasInputStreams: inputStreamBytes > 0, name: name,
      transport: transport, uid: uid)
  }

  private func propertySize(
    object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
      throw CoreAudioReadError.failed
    }
    return size
  }

  private func fixedValue<T>(
    object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) throws -> T {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
      size == UInt32(MemoryLayout<T>.size)
    else { throw CoreAudioReadError.failed }
    return pointer.move()
  }

  private func stringValue(
    object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
      size == UInt32(MemoryLayout.size(ofValue: value)), let value
    else { throw CoreAudioReadError.failed }
    // AudioHardwareBase.h assigns ownership of kAudioObjectPropertyName to the caller.
    return value.takeRetainedValue() as String
  }
}

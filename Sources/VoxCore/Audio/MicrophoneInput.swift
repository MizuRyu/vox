import Foundation

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
  public let id: UInt32
  public let name: String
  public let transport: AudioTransport
  public let uid: String?

  public init(id: UInt32, name: String, transport: AudioTransport = .unknown, uid: String? = nil) {
    self.id = id
    self.name = name
    self.transport = transport
    self.uid = uid
  }
}

public struct MicrophoneOutput: Equatable, Sendable {
  public let transport: AudioTransport
  public let isRunning: Bool

  public init(transport: AudioTransport, isRunning: Bool) {
    self.transport = transport
    self.isRunning = isRunning
  }
}

public enum MicrophoneInputError: Error, LocalizedError, CustomStringConvertible {
  case noInput, deviceUnavailable, invalidSelection, unavailable

  public var description: String {
    switch self {
    case .noInput: "既定のマイクが見つかりません。macOSの入力設定を確認してください。"
    case .deviceUnavailable: "指定したマイクが見つかりません。接続するか、設定で別のマイクを選んでください。"
    case .invalidSelection: "マイクの指定が空です。設定でマイクを選んでください。"
    case .unavailable: "マイクの情報を取得できません。接続を確認してからやり直してください。"
    }
  }

  public var errorDescription: String? { description }
}

public enum MicrophoneInput: Hashable, Sendable, Codable {
  case automatic
  case systemDefault
  case device(String)

  private enum CodingKeys: String, CodingKey { case mode, uid }
  private enum Mode: String, Codable { case automatic, systemDefault = "system_default", device }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Mode.self, forKey: .mode) {
    case .automatic: self = .automatic
    case .systemDefault: self = .systemDefault
    case .device: self = .device(try container.decode(String.self, forKey: .uid))
    }
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .automatic: try container.encode(Mode.automatic, forKey: .mode)
    case .systemDefault: try container.encode(Mode.systemDefault, forKey: .mode)
    case .device(let uid):
      try container.encode(Mode.device, forKey: .mode)
      try container.encode(uid, forKey: .uid)
    }
  }

  public func validate() throws {
    if case .device(let uid) = self, uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw MicrophoneInputError.invalidSelection
    }
  }

  public func resolve(
    devices: [MicrophoneDevice], defaultDeviceID: UInt32?, output: MicrophoneOutput?
  ) throws -> MicrophoneDevice {
    try validate()
    if case .device(let uid) = self {
      guard let device = devices.first(where: { $0.uid == uid }) else {
        throw MicrophoneInputError.deviceUnavailable
      }
      return device
    }
    guard let device = devices.first(where: { $0.id == defaultDeviceID }) else {
      throw MicrophoneInputError.noInput
    }
    // 再生中のBluetooth出力を保つため、入力だけを内蔵へ分ける。
    if self == .automatic, device.transport.isBluetooth,
      let output, output.transport.isBluetooth, output.isRunning,
      let builtIn = devices.first(where: { $0.transport == .builtIn }) {
      return builtIn
    }
    return device
  }

  public var logLabel: String {
    switch self {
    case .automatic: "automatic"
    case .systemDefault: "system_default"
    case .device: "device"
    }
  }
}

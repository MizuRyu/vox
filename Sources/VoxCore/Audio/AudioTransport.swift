// 入力デバイスの接続方式。診断ログの transport= と設定画面のマイク一覧で同じ分類を使う。

/// CoreAudio の `kAudioDevicePropertyTransportType`。
/// VoxCore に CoreAudio を持ち込まないので、値は four-char code の数値で持つ。
public enum AudioTransport: Equatable, Sendable {
  case builtIn
  case bluetooth
  case bluetoothLowEnergy
  case usb
  case aggregate
  case virtual
  /// CoreAudio が「不明」として定義する 0。
  case unknown
  /// 分類していない接続方式（HDMI、Thunderbolt など）。
  case other(UInt32)

  public init(rawValue: UInt32) {
    switch rawValue {
    case 0: self = .unknown
    case 0x626C_746E: self = .builtIn  // 'bltn'
    case 0x626C_7565: self = .bluetooth  // 'blue'
    case 0x626C_6561: self = .bluetoothLowEnergy  // 'blea'
    case 0x7573_6220: self = .usb  // 'usb '
    case 0x6772_7570: self = .aggregate  // 'grup'
    case 0x7669_7274: self = .virtual  // 'virt'
    default: self = .other(rawValue)
    }
  }

  /// 診断ログの `transport=`。分類できない値は突き合わせのために数値のまま出す。
  public var logLabel: String {
    switch self {
    case .builtIn: "builtin"
    case .bluetooth: "bluetooth"
    case .bluetoothLowEnergy: "bluetoothle"
    case .usb: "usb"
    case .aggregate: "aggregate"
    case .virtual: "virtual"
    case .unknown: "unknown"
    case .other(let rawValue): "\(rawValue)"
    }
  }

  /// 設定画面のマイク一覧に添える分類。見分けられないものには何も出さない。
  public var displayLabel: String? {
    switch self {
    case .builtIn: "内蔵"
    case .bluetooth: "Bluetooth"
    case .bluetoothLowEnergy: "Bluetooth LE"
    case .usb: "USB"
    case .aggregate: "集約"
    case .virtual: "仮想"
    case .unknown, .other: nil
    }
  }
}

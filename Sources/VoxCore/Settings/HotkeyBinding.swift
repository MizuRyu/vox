import Foundation

/// 修飾キー + 1 キーの組み合わせ。修飾キーは「指定したものが全部押されていて、指定していないものは押されていない」で一致させる。
public struct HotkeyBinding: Sendable, Equatable, CustomStringConvertible {
  public let keyCode: Int64
  public let command: Bool
  public let shift: Bool
  public let control: Bool
  public let option: Bool
  public let label: String

  public static let commandShiftSpace = HotkeyBinding(
    keyCode: 49, command: true, shift: true, control: false, option: false, label: "⌘⇧Space")
  /// パレットの既定（設計書 §4）。
  public static let controlP = HotkeyBinding(
    keyCode: 35, command: false, shift: false, control: true, option: false, label: "⌃P")

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.keyCode == rhs.keyCode && lhs.command == rhs.command && lhs.shift == rhs.shift
      && lhs.control == rhs.control && lhs.option == rhs.option
  }

  public var spec: String {
    var parts: [String] = []
    if control { parts.append("ctrl") }
    if option { parts.append("opt") }
    if command { parts.append("cmd") }
    if shift { parts.append("shift") }
    parts.append(Self.keyName(for: keyCode) ?? "unknown")
    return parts.joined(separator: "+")
  }

  private static func keyName(for code: Int64) -> String? {
    keyCodes.first { $0.value == code && !["enter", "backspace", "esc"].contains($0.key) }?.key
  }

  public static func recorded(
    keyCode: Int64, command: Bool, shift: Bool, control: Bool, option: Bool
  ) throws -> Self {
    guard keyName(for: keyCode) != nil else {
      throw HotkeySettingsError.invalidShortcut("このキー")
    }
    let binding = Self(keyCode: keyCode, command: command, shift: shift, control: control,
      option: option, label: "")
    let parsed = try Self.parse(binding.spec)
    try parsed.validateForSettings()
    return parsed
  }

  public func validateForSettings() throws {
    let functionKey = (Self.keyName(for: keyCode) ?? "").hasPrefix("f")
      && keyCode >= 96
    guard command || control || option || functionKey else {
      throw HotkeySettingsError.modifierRequired
    }
  }

  public var description: String { label }

  /// "ctrl+k" "cmd+shift+space" "opt+/" のような指定を解釈する。大文字小文字は区別しない。
  /// キー名は ANSI 配列の物理位置で解決する（a-z と記号は JIS でも同じ位置）。
  public static func parse(_ spec: String) throws -> HotkeyBinding {
    let parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard let keyName = parts.last, !keyName.isEmpty else { throw HotkeySettingsError.invalidShortcut(spec) }
    var command = false, shift = false, control = false, option = false
    for modifier in parts.dropLast() {
      switch modifier {
      case "cmd", "command", "⌘": command = true
      case "shift", "⇧": shift = true
      case "ctrl", "control", "⌃": control = true
      case "opt", "option", "alt", "⌥": option = true
      default: throw HotkeySettingsError.invalidShortcut(spec)
      }
    }
    guard let keyCode = keyCodes[keyName] else { throw HotkeySettingsError.invalidShortcut(spec) }
    var label = ""
    if control { label += "⌃" }
    if option { label += "⌥" }
    if shift { label += "⇧" }
    if command { label += "⌘" }
    label += keyName.count == 1 ? keyName.uppercased() : keyName.prefix(1).uppercased() + keyName.dropFirst()
    return HotkeyBinding(keyCode: keyCode, command: command, shift: shift, control: control, option: option, label: label)
  }

  /// ANSI 仮想キーコード（Carbon の kVK_ANSI_*）。
  private static let keyCodes: [String: Int64] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111
  ]
}

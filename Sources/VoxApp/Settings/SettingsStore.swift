import Foundation
import VoxCore

public struct SettingsStore: Sendable {
  public let url: URL
  public static var standard: Self {
    Self(url: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/vox/settings.json"))
  }

  public init(url: URL) { self.url = url }

  public func contents() throws -> Data? {
    let manager = FileManager.default
    guard let attributes = try? manager.attributesOfItem(atPath: url.path) else {
      if !manager.fileExists(atPath: url.path) { return nil }
      throw HotkeySettingsError.unreadableFile
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw HotkeySettingsError.unreadableFile
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 65_537) ?? Data()
    guard data.count <= 65_536 else { throw HotkeySettingsError.unreadableFile }
    return data
  }

  public func load() throws -> HotkeySettings {
    try decode(contents())
  }

  public func decode(_ data: Data?) throws -> HotkeySettings {
    guard let data else { return HotkeySettings() }
    let settings: HotkeySettings
    do { settings = try JSONDecoder().decode(HotkeySettings.self, from: data) } catch { throw HotkeySettingsError.unreadableFile }
    try settings.validate()
    return settings
  }

  public func save(_ settings: HotkeySettings) throws {
    try settings.validate()
    _ = try contents() // Reject symlinks and special files before replacing anything.
    let parent = url.deletingLastPathComponent()
    let manager = FileManager.default
    try manager.createDirectory(at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(settings)
    let temporary = parent.appendingPathComponent(".settings-\(UUID().uuidString).json")
    defer { try? manager.removeItem(at: temporary) }
    guard manager.createFile(atPath: temporary.path, contents: data,
      attributes: [.posixPermissions: 0o600])
    else { throw HotkeySettingsError.unreadableFile }
    if manager.fileExists(atPath: url.path) {
      _ = try manager.replaceItemAt(url, withItemAt: temporary)
    } else {
      try manager.moveItem(at: temporary, to: url)
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

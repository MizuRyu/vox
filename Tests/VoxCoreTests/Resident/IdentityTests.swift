// bundle identifier の正本は Resources/App/Info.plist。Swift の写しが黙って離れないよう固定する。

import Foundation
import Testing
import VoxCore

@Suite("Resident: アプリ自身の識別子")
struct VoxIdentityTests {
  private var infoPlist: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/App/Info.plist")
  }

  @Test("bundle identifier は Info.plist の値と一致する")
  func bundleIdentifierMatchesInfoPlist() throws {
    let values = try #require(
      PropertyListSerialization.propertyList(from: try Data(contentsOf: infoPlist), format: nil)
        as? [String: Any])
    #expect(values["CFBundleIdentifier"] as? String == "local.vox.app",
      "Info.plist の bundle identifier が変わっている")
  }
}

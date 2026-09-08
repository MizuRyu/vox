// 初期設定チェックリストの充足判定。

import Foundation
import Testing
import VoxCore

@Suite("Settings: 初期設定の充足")
struct SetupPermissionsTests {
  @MainActor
  @Test("Setup permission snapshot")
  func testSetupPermissionSnapshot() {
    for microphone in [
      ResidentMicrophoneAuthorization.notDetermined, .denied, .restricted, .unknown
    ] {
      let snapshot = SetupPermissions(
        microphone: microphone, accessibilityTrusted: true, postEventAccess: true,
        listenEventAccess: true)
      #expect(!snapshot.isGranted(.microphone), "unconfirmed microphone state is incomplete: \(microphone)")
      #expect(snapshot.completedCount == 2, "unconfirmed microphone state never counts as granted")
      #expect(!snapshot.isComplete, "unconfirmed microphone state never completes setup")
    }

    let missingPostAccess = SetupPermissions(
      microphone: .authorized, accessibilityTrusted: true, postEventAccess: false,
      listenEventAccess: true)
    #expect(!missingPostAccess.isGranted(.accessibility),
      "Accessibility requires trust and post-event access")
    #expect(missingPostAccess.completedCount == 2, "missing post-event access leaves setup at 2/3")

    let complete = SetupPermissions(
      microphone: .authorized, accessibilityTrusted: true, postEventAccess: true,
      listenEventAccess: true)
    #expect(complete.completedCount == 3, "all grants produce 3/3")
    #expect(complete.isComplete, "all grants complete setup")

    let revoked = SetupPermissions(
      microphone: .authorized, accessibilityTrusted: true, postEventAccess: true,
      listenEventAccess: false)
    #expect(revoked.completedCount == 2, "revocation returns setup to 2/3")
    #expect(!revoked.isComplete, "revocation returns setup to incomplete")
  }
}

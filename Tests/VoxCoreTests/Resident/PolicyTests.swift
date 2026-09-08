// 常駐の表示・対象・ログイン項目・権限の判断。

import Foundation
import Testing
import VoxCore

@Suite("Resident: 表示と権限の判断")
struct ResidentPolicyTests {
  @MainActor
  @Test("Resident presentation policy")
  func testResidentPresentationPolicy() {
    #expect(ResidentPresentation.statusTitle(for: .idle) == "待機中", "idle status title")
    #expect(ResidentPresentation.statusTitle(for: .recording) == "録音中", "recording status title")
    #expect(ResidentPresentation.primaryActionTitle(for: .recording) == "確定して貼り付け",
      "recording primary action")
    #expect(!ResidentPresentation.canToggleRecording(in: .finishing), "finishing disables toggle")
    #expect(ResidentPresentation.canToggleRecording(in: .permissionRequired),
      "permission state offers recheck")
  }

  @MainActor
  @Test("Resident target policy")
  func testResidentTargetPolicy() {
    #expect(!ResidentTargetPolicy.isEligible(bundleIdentifier: "local.vox.app"),
      "Vox is not a recording target")
    #expect(!ResidentTargetPolicy.isEligible(bundleIdentifier: "com.apple.systemuiserver"),
      "SystemUIServer is not a recording target")
    #expect(ResidentTargetPolicy.isEligible(bundleIdentifier: "com.apple.TextEdit"),
      "normal apps remain recording targets")
    #expect(!ResidentTargetPolicy.isEligible(bundleIdentifier: nil), "unknown app is not a target")
  }

  @MainActor
  @Test("Bundled defaults use application support")
  func testBundledDefaultsUseApplicationSupport() {
    let base = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
    #expect(ResidentPaths.defaultMetricsURL(applicationSupport: base).path ==
      "/tmp/Application Support/vox/metrics.jsonl", "bundled metrics stay in Application Support")
  }

  @MainActor
  @Test("Login item action policy")
  func testLoginItemActionPolicy() {
    #expect(ResidentLoginPolicy.action(for: .disabled) == .register, "disabled login item registers")
    #expect(ResidentLoginPolicy.action(for: .enabled) == .unregister, "enabled login item unregisters")
    #expect(ResidentLoginPolicy.action(for: .requiresApproval) == .openSystemSettings,
      "approval state opens System Settings")
    #expect(ResidentLoginPolicy.action(for: .unavailable) == .none,
      "unavailable login item performs no mutation")
  }

  @MainActor
  @Test("Resident permission policy")
  func testResidentPermissionPolicy() {
    #expect(ResidentPermissionPolicy.allowsHotkeys(for: .authorized), "authorized mic allows hotkeys")
    #expect(ResidentPermissionPolicy.allowsHotkeys(for: .notDetermined),
      "undetermined mic waits for user hotkey intent")
    #expect(!ResidentPermissionPolicy.allowsHotkeys(for: .restricted),
      "restricted mic never reports ready")
    #expect(ResidentPermissionPolicy.startupPhase(for: .denied) == .permissionRequired,
      "denied mic requests recovery")
    #expect(ResidentPermissionPolicy.startupPhase(for: .unknown) == .error,
      "unknown mic state reports error")
    #expect(ResidentPermissionPolicy.primaryAction(for: .recording) == .performImmediately,
      "recording can always be stopped after permission revocation")
    #expect(ResidentPermissionPolicy.primaryAction(for: .idle) == .checkPermissions,
      "idle recording start checks permissions")
  }

  @MainActor
  @Test("Resident control policy")
  func testResidentControlPolicy() {
    #expect(
      ResidentControlPolicy.shouldShowWindow(
        for: .startup(isBundled: true, launchedAtLogin: false), permissionsReady: true),
      "ordinary bundled startup shows resident controls")
    #expect(
      !ResidentControlPolicy.shouldShowWindow(
        for: .startup(isBundled: true, launchedAtLogin: true), permissionsReady: true),
      "login launch stays quiet when permissions are ready")
    #expect(
      ResidentControlPolicy.shouldShowWindow(
        for: .startup(isBundled: true, launchedAtLogin: true), permissionsReady: false),
      "login launch exposes permission recovery when required")
    #expect(
      ResidentControlPolicy.shouldShowWindow(for: .reopen, permissionsReady: true),
      "Finder reopen always shows resident controls")
  }

  @MainActor
  @Test("Resident palette fallback policy")
  func testResidentPaletteFallbackPolicy() {
    #expect(!ResidentPalettePolicy.allowsCurrentDirectoryFallback(isBundled: true),
      "bundle launch never scans its current directory")
    #expect(ResidentPalettePolicy.allowsCurrentDirectoryFallback(isBundled: false),
      "CLI keeps current-directory fallback")
  }
}

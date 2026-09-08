// 音声認識アセットの用意ができているかの判定。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: 音声アセットの用意")
struct SpeechAssetTests {
  @MainActor
  @Test("Installed speech locale overrides stale supported status")
  func testInstalledSpeechLocaleOverridesStaleSupportedStatus() {
    #expect(
      SpeechAssetReadiness.isReady(
        localeIdentifier: "ja-JP", installedLocaleIdentifiers: ["ja-JP"],
        moduleStatus: .supported),
      "installed speech locale is ready when module status remains supported")
  }

  @MainActor
  @Test("Supported speech asset without installed locale needs installation")
  func testSupportedSpeechAssetWithoutInstalledLocaleNeedsInstallation() {
    #expect(
      !SpeechAssetReadiness.isReady(
        localeIdentifier: "ja-JP", installedLocaleIdentifiers: [], moduleStatus: .supported),
      "supported speech asset without its installed locale is not ready")
  }

  @MainActor
  @Test("Different installed speech locale does not satisfy japanese")
  func testDifferentInstalledSpeechLocaleDoesNotSatisfyJapanese() {
    #expect(
      !SpeechAssetReadiness.isReady(
        localeIdentifier: "ja-JP", installedLocaleIdentifiers: ["en-US"],
        moduleStatus: .supported),
      "an installed locale other than Japanese does not make Japanese ready")
  }

  @MainActor
  @Test("Installed module status is ready when locale list lags")
  func testInstalledModuleStatusIsReadyWhenLocaleListLags() {
    #expect(
      SpeechAssetReadiness.isReady(
        localeIdentifier: "ja-JP", installedLocaleIdentifiers: [], moduleStatus: .installed),
      "installed module status is ready when the installed locale list lags")
  }

  @MainActor
  @Test("Absent speech locale is not ready for non installed statuses")
  func testAbsentSpeechLocaleIsNotReadyForNonInstalledStatuses() {
    for status: SpeechAssetModuleStatus in [.unsupported, .downloading, .unknown] {
      #expect(
        !SpeechAssetReadiness.isReady(
          localeIdentifier: "ja-JP", installedLocaleIdentifiers: [], moduleStatus: status),
        "absent speech locale is not ready for status \(status)")
    }
  }
}

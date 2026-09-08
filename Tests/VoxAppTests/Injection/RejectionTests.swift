// A-5。挿入を拒否した回の後始末。本文をクリップボードに残すかどうかだけを見る
// （キー送出も AX も通らない経路。pasteboard は名前付きの private なものを使う）。

import AppKit
import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Injection: 拒否した回の本文")
struct RejectionTests {
  @Test("修飾キーの解放待ちで拒否しても、本文はクリップボードに残る")
  func rejectionKeepsTheTextOnTheClipboard() {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("dev.vox.rejection.\(getpid()).\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let injector = Injector(pasteboard: pasteboard)
    let target = CapturedInjectionTarget(
      safetyIdentity: InjectionTarget(processID: 1, focusedElement: .unknown),
      focusedElement: nil)

    let outcome = injector.rejectionOutcome(
      reason: .modifiersHeld, text: "確定した本文", target: target, current: nil,
      preparation: Injector.PostPreparation(), modifierWait: 300)

    #expect(outcome.error == "modifier_release_timeout", "拒否の理由が変わった")
    #expect(outcome.clipboardContainsText, "拒否した回に本文を残さなかった")
    #expect(pasteboard.string(forType: .string) == "確定した本文", "クリップボードに本文が無い")
  }
}

// R16 activate の判定。

import Foundation
import Testing
import VoxCore

@Suite("Injection: activate の判定")
struct ActivationPolicyTests {
  @Test("Activation is skipped when target is already frontmost")
  func activationIsSkippedWhenTargetIsAlreadyFrontmost() throws {
    #expect(!ActivationPolicy.needsActivation(frontmostProcessID: 42, targetProcessID: 42), "前面が挿入先なのに activate しようとした")
  }

  @Test("Activation is skipped when target is unknown")
  func activationIsSkippedWhenTargetIsUnknown() throws {
    #expect(!ActivationPolicy.needsActivation(frontmostProcessID: 42, targetProcessID: nil), "挿入先が不明なのに activate しようとした")
  }

  @Test("Activation is needed when frontmost moved")
  func activationIsNeededWhenFrontmostMoved() throws {
    #expect(ActivationPolicy.needsActivation(frontmostProcessID: 7, targetProcessID: 42), "前面が変わったのに activate しない")
  }

  @Test("Activation timeout is reported with elapsed time")
  func activationTimeoutIsReportedWithElapsedTime() throws {
    let ok = ActivationPolicy.outcome(becameFrontmost: true, elapsedMilliseconds: 66)
    #expect((ok.milliseconds == 66) && (ok.error == nil), "activate 成功の記録が違う")
    let timedOut = ActivationPolicy.outcome(becameFrontmost: false, elapsedMilliseconds: 500)
    #expect((timedOut.milliseconds == 500) && (timedOut.error == "target_activate_timeout"), "activate タイムアウトの記録が違う")
  }
}

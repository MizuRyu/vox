import Foundation
import Testing
import VoxCore

@Suite("Injection: 自動 Enter")
struct AutoEnterTests {
  /// 検査が共有する「置き換え前 / 計画 / 置き換え後」。
  private func autoEnterFixture() -> (
    before: TextInsertionSnapshot, plan: AutoEnterPlan?, after: TextInsertionSnapshot
  ) {
    let before = TextInsertionSnapshot(value: "前🙂後", selection: NSRange(location: 1, length: 2))
    return (
      before, AutoEnterPlan(before: before, insertedText: "音声"),
      TextInsertionSnapshot(value: "前音声後", selection: NSRange(location: 3, length: 0))
    )
  }

  @Test("auto Enter は入力欄の置き換えを UTF16 で確かめる")
  func autoEnterPlanChecks() {
    let (before, plan, after) = autoEnterFixture()
    #expect(plan?.matches(after) == true, "auto Enter verifies UTF16 selection replacement")
    #expect(
      plan?.matches(before) == false, "clipboard receipt cannot substitute for input value change")
    #expect(
      plan?.matches(.init(value: after.value, selection: NSRange(location: 1, length: 0))) == false,
      "auto Enter rejects moved caret")
    #expect(
      AutoEnterPlan(before: before, insertedText: "") == nil, "auto Enter rejects empty dictation")
    #expect(
      AutoEnterPlan(before: before, insertedText: "🙂") == nil,
      "auto Enter rejects unchanged replacement")
    #expect(
      AutoEnterPlan(
        before: .init(value: "🙂", selection: NSRange(location: 1, length: 0)), insertedText: "a")
        == nil,
      "auto Enter rejects split surrogate selection")
    #expect(
      AutoEnterPlan(
        before: .init(value: "a", selection: NSRange(location: Int.max, length: 1)), insertedText: "b"
      ) == nil,
      "auto Enter rejects overflowing selection")
    #expect(
      AutoEnterPlan(
        before: .init(
          value: String(repeating: "x", count: 65_537), selection: NSRange(location: 0, length: 0)),
        insertedText: "b") == nil,
      "auto Enter bounds input readback")
  }

  @MainActor
  @Test("読み返せる入力欄では各条件で打鍵数と結果が決まる")
  func autoEnterGateChecks() async {
    let (before, plan, after) = autoEnterFixture()
    let original = InjectionTarget(processID: 42, focusedElement: .known(1))
    let changed = InjectionTarget(processID: 43, focusedElement: .known(1))
    // 読み返せる入力欄の結果は「確認できないアプリでも送る」に左右されない。
    for sendWhenUnverified in [false, true] {
      for scenario in [
        "success", "disabled", "unknown", "unsupported", "timeout", "target", "modifier",
        "stalledModifier", "modifierClears", "cancelWhileModifier", "clipboardWhileModifier",
        "targetWhileModifier",
        "cancel", "clipboard", "changedDuringRead", "changedValue", "postFailure", "late", "nil",
        "delayed", "cancelAfterWait", "clipboardDuringRead", "modifierDuringRead"
      ] {
        var reads = 0
        var posts = 0
        var time = 0.0
        let result = await AutoEnterGate.run(
          enabled: scenario != "disabled", sendWhenUnverified: sendWhenUnverified,
          plan: scenario == "unsupported" ? nil : plan,
          original: scenario == "unknown" ? .init(processID: 42, focusedElement: .unknown) : original,
          pastePostedAt: 0,
          probes: .init(
            currentTarget: {
              scenario == "target" || (scenario == "targetWhileModifier" && time > 0)
                || (scenario == "changedDuringRead" && reads > 0) ? changed : original
            },
            modifiersHeld: {
              scenario == "modifier" || scenario == "stalledModifier"
                || ((scenario == "modifierClears" || scenario.hasSuffix("WhileModifier")) && time < 0.3)
                || (scenario == "modifierDuringRead" && reads > 0)
            },
            isCancelled: {
              scenario == "cancel"
                || ((scenario == "cancelAfterWait" || scenario == "cancelWhileModifier") && time > 0)
            },
            clipboardOwned: {
              scenario != "clipboard" && !(scenario == "clipboardDuringRead" && reads > 0)
                && !(scenario == "clipboardWhileModifier" && time > 0)
            },
            readback: {
              reads += 1
              if scenario == "late" { time = 2 }
              if scenario == "nil" { return nil }
              if ["delayed", "cancelAfterWait"].contains(scenario) && time == 0 { return before }
              return scenario == "timeout" || (scenario == "changedValue" && reads > 1) ? before : after
            },
            sameWindow: { true },
            postReturn: {
              posts += 1
              return scenario != "postFailure"
            },
            now: { time }, wait: { if scenario != "stalledModifier" { time += 0.1 } }))
        checkAutoEnterScenario(
          scenario: scenario, sendWhenUnverified: sendWhenUnverified, result: result, posts: posts,
          reads: reads)
      }
    }
    let invalidClock = await AutoEnterGate.run(
      enabled: true, sendWhenUnverified: false, plan: plan, original: original, pastePostedAt: 0,
      probes: .init(
        currentTarget: { original }, modifiersHeld: { false }, isCancelled: { false },
        clipboardOwned: { true }, readback: { after }, sameWindow: { true },
        postReturn: { false }, now: { .nan }, wait: {}))
    #expect(invalidClock == .invalidClock, "verified Enter identifies invalid monotonic clock")
  }

  private func checkAutoEnterScenario(
    scenario: String, sendWhenUnverified: Bool, result: AutoEnterResult, posts: Int, reads: Int
  ) {
    let label = "\(scenario) unverified=\(sendWhenUnverified)"
    #expect(
      posts == (["success", "postFailure", "delayed", "modifierClears"].contains(scenario) ? 1 : 0),
      "auto Enter event count: \(label)")
    #expect(
      (result == .posted) == (["success", "delayed", "modifierClears"].contains(scenario)),
      "auto Enter outcome: \(label)")
    if scenario == "unknown" || scenario == "unsupported" || scenario == "nil" {
      #expect(result == .inputUnavailable, "unreadable input reports unavailable input: \(label)")
    } else if scenario == "timeout" || scenario == "late" {
      #expect(result == .timedOut, "expired verification reports timeout: \(label)")
    } else if scenario == "changedValue" {
      #expect(result == .readbackMismatch, "changed final readback reports mismatch: \(label)")
    } else if scenario == "modifier" || scenario == "stalledModifier" {
      #expect(result == .modifiersHeld, "permanent modifier reports modifier rejection: \(label)")
    } else if scenario == "cancelWhileModifier" {
      #expect(result == .cancelled, "cancellation wins while waiting for modifier: \(label)")
    } else if scenario == "clipboardWhileModifier" {
      #expect(result == .clipboardChanged, "clipboard change wins while waiting for modifier: \(label)")
    } else if scenario == "targetWhileModifier" {
      #expect(result == .targetChanged, "target change wins while waiting for modifier: \(label)")
    }
    if scenario == "disabled" {
      #expect(reads == 0, "disabled auto Enter reads no input contents")
    }
  }

  @Test("安全でない入力欄は読まない")
  func inputSubroleChecks() {
    #expect(
      InputSubroleState.missing.allowsTextInspection, "ordinary text fields may omit AXSubrole")
    #expect(
      InputSubroleState.named("AXUnknown").allowsTextInspection, "ordinary subrole permits readback")
    #expect(
      !InputSubroleState.named("AXSecureTextField").allowsTextInspection,
      "secure text fields are never read")
    #expect(
      !InputSubroleState.failed.allowsTextInspection, "AX communication failure remains a rejection")
    #expect(
      !AutoEnterResult.postedUnverified.isVerifiedInsertion,
      "unverified Return is not verified insertion")
    #expect(
      AutoEnterResult.posted.isVerifiedInsertion,
      "readback-verified Return records verified insertion")
  }

  @MainActor
  @Test("貼り付け直後の Enter は単調時計の窓の中で打つ")
  func unverifiedClockChecks() async {
    // 呼び出し側は ms で測った post 時刻を秒に直して渡す。尺度が食い違えば窓がずれる。
    #expect(
      abs(VoxMonotonicClock.nowMilliseconds() / 1_000 - VoxMonotonicClock.nowSeconds()) < 0.1,
      "production monotonic clock reports one scale in milliseconds and seconds")
    let invalidClock = await AutoEnterGate.run(
      enabled: true, sendWhenUnverified: true, plan: nil,
      original: .init(processID: 12, focusedElement: .unknown), pastePostedAt: 1,
      probes: .init(
        currentTarget: { .init(processID: 12, focusedElement: .unknown) },
        modifiersHeld: { false }, isCancelled: { false }, clipboardOwned: { true },
        readback: { nil }, sameWindow: { true },
        postReturn: { false }, now: { .nan }, wait: {}))
    #expect(invalidClock == .invalidClock, "unverified Enter identifies invalid monotonic clock")
  }

  @MainActor
  @Test("読み返せない入力欄では不正な時計より先に取り消しを見る")
  func unverifiedCancelledBeforeInvalidClock() async {
    let result = await AutoEnterGate.run(
      enabled: true, sendWhenUnverified: true, plan: nil,
      original: .init(processID: 12, focusedElement: .unknown), pastePostedAt: .nan,
      probes: .init(
        currentTarget: { .init(processID: 12, focusedElement: .unknown) },
        modifiersHeld: { false }, isCancelled: { true }, clipboardOwned: { true },
        readback: { nil }, sameWindow: { true },
        postReturn: { false }, now: { .nan }, wait: {}))
    #expect(result == .cancelled, "cancellation wins even when the input cannot be read back")
  }

  @MainActor
  @Test("読み返せない入力欄では設定が送るかを決める")
  func unverifiedScenarioChecks() async {
    for sendWhenUnverified in [true, false] {
      for scenario in [
        "normal", "knownFocus", "wrongWindow", "noWindow", "wrongPID", "knownFocusChanged",
        "modifiers", "stalledModifier", "modifierClears", "windowWhileModifier",
        "cancelWhileModifier", "clipboardWhileModifier",
        "cancel", "clipboard", "windowAfterWait", "cancelAfterWait", "eventFailure", "late"
      ] {
        let original = InjectionTarget(
          processID: 12, focusedElement: scenario.hasPrefix("known") ? .known(1) : .unknown)
        var time = 0.1
        var postedAt: Double?
        var posts = 0
        let result = await AutoEnterGate.run(
          enabled: true, sendWhenUnverified: sendWhenUnverified, plan: nil, original: original,
          pastePostedAt: scenario == "late" ? -5 : 0,
          probes: .init(
            currentTarget: {
              .init(
                processID: scenario == "wrongPID" ? 99 : 12,
                focusedElement: scenario == "knownFocusChanged" ? .known(2) : original.focusedElement)
            },
            modifiersHeld: {
              scenario == "modifiers" || scenario == "stalledModifier"
                || (scenario.hasSuffix("WhileModifier") && time < 0.4)
                || (scenario == "modifierClears" && time < 0.3)
            },
            isCancelled: {
              scenario == "cancel" || (scenario == "cancelAfterWait" && time >= 0.5)
                || (scenario == "cancelWhileModifier" && time >= 0.2)
            },
            clipboardOwned: {
              scenario != "clipboard" && !(scenario == "clipboardWhileModifier" && time >= 0.2)
            },
            readback: { nil },
            sameWindow: {
              !["wrongWindow", "noWindow"].contains(scenario)
                && !(scenario == "windowAfterWait" && time >= 0.5)
                && !(scenario == "windowWhileModifier" && time >= 0.2)
            },
            postReturn: {
              posts += 1
              postedAt = time
              return scenario != "eventFailure"
            },
            now: { time }, wait: { if scenario != "stalledModifier" { time += 0.1 } }))
        if sendWhenUnverified {
          checkUnverifiedScenario(
            scenario: scenario, result: result, posts: posts, postedAt: postedAt)
        } else {
          #expect(result == .unverifiable, "unreadable input sends nothing by default: \(scenario)")
          #expect(posts == 0, "unreadable input posts no Return by default: \(scenario)")
        }
      }
    }
  }

  private func checkUnverifiedScenario(
    scenario: String, result: AutoEnterResult, posts: Int, postedAt: Double?
  ) {
    let shouldPost = ["normal", "knownFocus", "modifierClears", "eventFailure"].contains(scenario)
    #expect(posts == (shouldPost ? 1 : 0), "unverified Enter event count: \(scenario)")
    #expect(
      (result == .postedUnverified) == ["normal", "knownFocus", "modifierClears"].contains(scenario),
      "unverified Enter result: \(scenario)")
    if scenario == "late" {
      #expect(result == .timedOut, "unverified expired paste reports timeout")
    } else if scenario == "modifiers" || scenario == "stalledModifier" {
      #expect(result == .modifiersHeld, "unverified permanent modifier reports modifier rejection")
    } else if scenario == "windowWhileModifier" {
      #expect(
        result == .windowUnverified, "unverified window change wins while waiting for modifier")
    } else if scenario == "cancelWhileModifier" {
      #expect(result == .cancelled, "unverified cancellation wins while waiting for modifier")
    } else if scenario == "clipboardWhileModifier" {
      #expect(
        result == .clipboardChanged, "unverified clipboard change wins while waiting for modifier")
    }
    if let postedAt { #expect(postedAt >= 0.5, "unverified Enter waits after paste: \(scenario)") }
  }
}

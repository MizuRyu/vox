// 前面アプリへのテキスト挿入。ADR-009 の promise pasteboard 方式。
// promise は置いたまま、provideDataForType の呼び出しを軸 A の終点（受領証）として使う。
//
// T19: **受領証を復元の合図に使うのをやめた。** 受領証は「最初に読んだ誰か」の印で、
// 対象アプリがペーストを処理し終えた印ではない（クリップボード履歴ツールが読んでも立つ。ADR-009 の追記）。
// 復元は Cmd+V の post から数えた時間で行い、Chromium / Electron 系には長い猶予を与える。
// 受領証の直後と復元の直前に自分で読み返し、置いた文字数との差を計測とログに残す（pasted_chars / readback_chars）。

import AppKit
import Carbon
import Foundation
import VoxCore

struct InjectionOutcome {
  let pastePostedMilliseconds: Double
  /// 受領証。1.5s 以内に来なければ nil。
  let pasteReceivedMilliseconds: Double?
  /// T19。復元を予約したか。実際の復元は猶予のあと（挿入の戻りを待たせない）。
  let clipboardRestored: Bool
  /// 合成 Cmd+V の前に修飾キーの解放を待った時間。待たなければ 0。
  let modifierWaitMilliseconds: Double
  /// T19。pasteboard に置いた確定テキストの文字数。
  let pastedCharacters: Int
  /// T19。受領証の直後に自分で読み返した文字数。読み返す前に返る経路では nil。
  let readbackCharacters: Int?
  /// The requested text is still on the clipboard after an insertion failure.
  let clipboardContainsText: Bool
  /// Only an app-specific readback can set this. A pasteboard receipt is insufficient.
  let pasteVerified: Bool
  let error: String?
  /// Cmd+V を送ったか。送っていない回（拒否）の通知は「挿入しませんでした」になる。
  var pastePosted = true
  var autoEnterResult: AutoEnterResult = .disabled
}

struct CapturedInjectionTarget {
  let safetyIdentity: InjectionTarget
  let focusedElement: AXUIElement?
  var focusedWindow: AXUIElement?
}

final class Injector: NSObject, NSPasteboardTypeOwner, @unchecked Sendable {
  /// 受領証を待つ上限。
  static let receiptTimeoutMilliseconds = 1500.0
  /// Cmd+V の post から復元までの猶予（既定の消費者）。
  static let restoreDelayMilliseconds = 400
  /// Chromium / Electron 系の猶予。post 後もかなり経ってから読む（ADR-009 の表の OpenSuperWhisper に合わせる）。
  static let asyncConsumerRestoreDelayMilliseconds = 1500
  /// 埋め込み Chromium の有無で判定できないアプリの明示指定。
  static let asyncConsumerBundleIdentifiers: Set<String> = [
    "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser", "com.apple.Safari", "org.mozilla.firefox",
    // WebView2（Edge の webview）で描く。Frameworks に Chromium のヘルパを置かない。
    "com.microsoft.teams2"
  ]
  /// 物理修飾キーの解放を待つ上限（M1 の未検証リスク 1）。
  static let modifierReleaseTimeoutMilliseconds = 300.0
  /// AX の問い合わせを待つ上限。無応答のアプリでも録音と確定を止めない。
  static let messagingTimeoutSeconds: Float = 0.5
  static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  private let lock = NSLock()
  /// 本文を置く先。検査が利用者のクリップボードを触らないよう、名前付きのものを渡せる。
  private let generalPasteboard: NSPasteboard
  private var pendingText = ""
  private var receiptMilliseconds: Double?
  private var ownedChangeCount: Int?

  init(pasteboard: NSPasteboard = .general) {
    generalPasteboard = pasteboard
    super.init()
  }

  /// promise を読まれたときに呼ばれる。ここが軸 A の終点。
  /// 任意のスレッドから呼ばれうるので lock で守る。
  func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
    let at = voxNowMilliseconds()
    lock.lock()
    let text = pendingText
    let ownsPasteboard = ownedChangeCount == sender.changeCount
    if ownsPasteboard, receiptMilliseconds == nil, type == .string {
      receiptMilliseconds = at
    }
    lock.unlock()

    guard let expectedChangeCount = lock.withLock({ ownedChangeCount }) else { return }
    ClipboardSafety.mutateIfOwned(
      expectedChangeCount: expectedChangeCount, currentChangeCount: sender.changeCount
    ) {
      if type == .string {
        sender.setData(Data(text.utf8), forType: .string)
        voxLog("paste_receipt at_ms=\(at)")
      } else {
        // ConcealedType は「履歴ツールに拾わせない」印なので中身は空でよい。
        sender.setData(Data(), forType: type)
      }
    }
  }

  @MainActor
  func insert(
    text: String, target: CapturedInjectionTarget, autoEnterEnabled: Bool = false,
    autoEnterUnverified: Bool = false,
    cancelAutoEnter: @escaping () -> Bool = { Task.isCancelled }
  ) async -> InjectionOutcome {
    // トグルキーの修飾（⌃ など）を握ったまま OFF すると、合成イベントの ⌘ と合流して
    // ⌘⌃V になりうる（M1 の未検証リスク 1）。promise を置く前に待つ。declareTypes の後に待つと、
    // クリップボード履歴ツールが promise を読んだ受領証が Cmd+V より先に立って軸 A が壊れる。
    // R16 の activate 済みなので、この時点の前面アプリが挿入先。復元の猶予をこれで決める。
    let targetApplication = NSWorkspace.shared.runningApplications.first {
      $0.processIdentifier == target.safetyIdentity.processID
    }
    let restoreDelay = Self.restoreDelay(for: targetApplication)
    var preparation = PostPreparation()
    var modifierWait = 0.0
    // 拒否の切り分けに使う。最後に見た確定時の要素を残す（拒否のときだけ読む）。
    var currentCapture: CapturedInjectionTarget?
    let orchestration = await InjectionOrchestrator.run(
      original: target.safetyIdentity,
      currentTarget: {
        let capture = Self.currentSafetyTarget(for: target)
        currentCapture = capture
        return capture.safetyIdentity
      },
      modifiersHeld: { Self.modifiersHeld() },
      isCancelled: { Task.isCancelled },
      waitForModifierRelease: { modifierWait = await Self.waitForModifierRelease() },
      prepareToPost: {
        preparation = self.preparePost(
          text: text, target: target, autoEnterEnabled: autoEnterEnabled)
      },
      postEvent: {
        guard let down = preparation.down, let up = preparation.up else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
      })

    if case .rejected(let reason) = orchestration {
      return rejectionOutcome(
        reason: reason, text: text, target: target, current: currentCapture,
        preparation: preparation, modifierWait: modifierWait)
    }
    guard let pasteboard = preparation.pasteboard, let changeCount = preparation.changeCount else {
      return Self.failure(text: text, error: preparation.error ?? "cg_event_creation_failed")
    }
    if let preparationError = preparation.error {
      Self.restore(preparation.saved, to: pasteboard, expectedChangeCount: changeCount)
      return Self.failure(text: text, error: preparationError, modifierWait: modifierWait)
    }
    let postedMilliseconds = voxNowMilliseconds()
    voxLog(
      "paste_posted at_ms=\(postedMilliseconds) key_code=\(preparation.keyCode) "
        + "modifier_wait_ms=\(modifierWait)"
    )

    let receipt = await waitForReceipt(from: postedMilliseconds)
    guard let receipt else {
      return receiptTimeoutOutcome(
        text: text, pasteboard: pasteboard, changeCount: changeCount, modifierWait: modifierWait,
        postedMilliseconds: postedMilliseconds)
    }

    // 受領証の直後に自分で読み返す。ここで全長が取れていれば、消費者が読んだ時点の
    // pasteboard には全量が載っていた（欠落は消費者側）と言える。
    let readback = pasteboard.string(forType: .string)?.count
    voxLog(
      "paste_lengths pasted_chars=\(text.count) readback_chars=\(readback.map(String.init) ?? "nil") "
        + "restore_delay_ms=\(restoreDelay) target=\(targetApplication?.bundleIdentifier ?? "unknown")"
    )

    let autoEnter = await Self.decideAutoEnter(
      enabled: autoEnterEnabled, sendWhenUnverified: autoEnterUnverified,
      plan: preparation.autoEnterPlan,
      target: target, postedMilliseconds: postedMilliseconds,
      probes: AutoEnterProbes(
        currentTarget: { Self.currentSafetyTarget(for: target, timeout: 0.05).safetyIdentity },
        modifiersHeld: { Self.returnModifiersHeld() }, isCancelled: cancelAutoEnter,
        clipboardOwned: { pasteboard.changeCount == changeCount },
        readback: { AccessibleInput.snapshot(target.focusedElement) },
        sameWindow: { Self.isSameWindow(as: target) },
        postReturn: { Self.postReturn() }, now: { VoxMonotonicClock.nowSeconds() },
        wait: { try? await Task.sleep(for: .milliseconds(20)) }))

    // Restore only after verification finishes, so it cannot race the ownership check above.
    // 復元は猶予のあとに別タスクで行う。await して返すと HUD が閉じるのがその分遅れる。
    scheduleRestore(
      preparation.saved, to: pasteboard, changeCount: changeCount, expectedCharacters: text.count,
      after: restoreDelay, from: postedMilliseconds)

    return InjectionOutcome(
      pastePostedMilliseconds: postedMilliseconds, pasteReceivedMilliseconds: receipt,
      clipboardRestored: true, modifierWaitMilliseconds: modifierWait,
      pastedCharacters: text.count, readbackCharacters: readback, clipboardContainsText: true,
      pasteVerified: autoEnter.isVerifiedInsertion, error: nil, autoEnterResult: autoEnter)
  }

  /// promise を置いて Cmd+V のイベントを作るまでの状態。失敗は `error` に残して呼び出し側が判断する。
  struct PostPreparation {
    var pasteboard: NSPasteboard?
    var saved: [NSPasteboardItem] = []
    var changeCount: Int?
    var down: CGEvent?
    var up: CGEvent?
    var keyCode: CGKeyCode = 9
    var error: String?
    var autoEnterPlan: AutoEnterPlan?
  }

  @MainActor
  private func preparePost(
    text: String, target: CapturedInjectionTarget, autoEnterEnabled: Bool
  ) -> PostPreparation {
    var preparation = PostPreparation()
    if autoEnterEnabled,
      let baseline = AccessibleInput.snapshot(target.focusedElement),
      baseline == AccessibleInput.snapshot(target.focusedElement) {
      preparation.autoEnterPlan = AutoEnterPlan(before: baseline, insertedText: text)
    }
    let currentPasteboard = generalPasteboard
    preparation.pasteboard = currentPasteboard
    preparation.saved = Self.snapshot(currentPasteboard)
    lock.withLock {
      pendingText = text
      receiptMilliseconds = nil
    }
    let ownedCount = currentPasteboard.declareTypes([.string, Self.concealedType], owner: self)
    preparation.changeCount = ownedCount
    lock.withLock { ownedChangeCount = ownedCount }
    guard
      let source = CGEventSource(stateID: .privateState)
        ?? CGEventSource(stateID: .hidSystemState)
    else {
      preparation.error = "cg_event_source_unavailable"
      return preparation
    }
    let keyCode = Self.pasteKeyCode()
    preparation.keyCode = keyCode
    preparation.down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    preparation.up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    if preparation.down == nil || preparation.up == nil {
      preparation.error = "cg_event_creation_failed"
    }
    return preparation
  }

  @MainActor
  func rejectionOutcome(
    reason: InjectionRejection?, text: String, target: CapturedInjectionTarget,
    current: CapturedInjectionTarget?, preparation: PostPreparation, modifierWait: Double
  ) -> InjectionOutcome {
    if let pasteboard = preparation.pasteboard, let changeCount = preparation.changeCount {
      Self.restore(preparation.saved, to: pasteboard, expectedChangeCount: changeCount)
    }
    let error: String
    if Task.isCancelled {
      error = "injection_cancelled"
    } else {
      error = reason?.rawValue ?? "input_target_changed"
      Self.logRejection(error, original: target, current: current)
    }
    // A-5。貼らないと決めた回も本文は残す（履歴を掘らずに貼り直せる）。
    let onClipboard = copyToClipboard(text: text)
    return Self.failure(
      text: text, error: error, modifierWait: modifierWait, clipboardContainsText: onClipboard)
  }

  /// 受領証が来ない。復元すると「クリップボードにある」が嘘になるので、
  /// promise を実データに置き換えて残す。
  @MainActor
  private func receiptTimeoutOutcome(
    text: String, pasteboard: NSPasteboard, changeCount: Int, modifierWait: Double,
    postedMilliseconds: Double
  ) -> InjectionOutcome {
    lock.withLock { pendingText = text }
    let stillOwned = ClipboardSafety.mutateIfOwned(
      expectedChangeCount: changeCount, currentChangeCount: pasteboard.changeCount
    ) { pasteboard.setData(Data(text.utf8), forType: .string) }
    return InjectionOutcome(
      pastePostedMilliseconds: postedMilliseconds, pasteReceivedMilliseconds: nil,
      clipboardRestored: false, modifierWaitMilliseconds: modifierWait,
      pastedCharacters: text.count,
      readbackCharacters: stillOwned ? pasteboard.string(forType: .string)?.count : nil,
      clipboardContainsText: stillOwned, pasteVerified: false,
      error: stillOwned ? "paste_receipt_timeout" : "clipboard_changed")
  }

  @MainActor
  private static func decideAutoEnter(
    enabled: Bool, sendWhenUnverified: Bool, plan: AutoEnterPlan?, target: CapturedInjectionTarget,
    postedMilliseconds: Double, probes: AutoEnterProbes
  ) async -> AutoEnterResult {
    let autoEnter = await AutoEnterGate.run(
      enabled: enabled, sendWhenUnverified: sendWhenUnverified, plan: plan,
      original: target.safetyIdentity,
      pastePostedAt: postedMilliseconds / 1000, probes: probes)
    if autoEnter == .modifiersHeld { Self.logReturnModifierState() }
    if enabled { voxLog("auto_enter result=\(autoEnter.rawValue)") }
    return autoEnter
  }

  /// 猶予をおいてから復元する。猶予は受領証ではなく Cmd+V の post から数える
  /// （受領証はクリップボード履歴ツールの読みでも立つので、窓を縮める合図には使えない）。
  /// 復元の直前にもう一度読み返し、置いた文字数と食い違う回は復元せず確定テキストを残す。
  @MainActor
  private func scheduleRestore(
    _ saved: [NSPasteboardItem], to pasteboard: NSPasteboard, changeCount: Int,
    expectedCharacters: Int, after milliseconds: Int, from postedMilliseconds: Double
  ) {
    Task { @MainActor in
      let remaining = Double(milliseconds) - (voxNowMilliseconds() - postedMilliseconds)
      if remaining > 0 {
        try? await Task.sleep(for: .milliseconds(Int(remaining.rounded(.up))))
      }
      let readback = pasteboard.string(forType: .string)?.count
      // 次の挿入が始まっていたら changeCount が動いている。そこへ復元をかけない。
      if pasteboard.changeCount != changeCount {
        voxLog("clipboard_restore skipped reason=change_count_moved")
      } else if readback != expectedCharacters {
        voxLog(
          "clipboard_restore skipped reason=readback_mismatch "
            + "readback_chars=\(readback.map(String.init) ?? "nil")")
      } else {
        Self.restore(saved, to: pasteboard, expectedChangeCount: changeCount)
        voxLog("clipboard_restore done delay_ms=\(milliseconds)")
      }
    }
  }

  /// T19。復元の猶予。Chromium / Electron 系は Cmd+V を受けてからも非同期に読み・描画を続けるので長くする。
  /// 埋め込み Chromium はバンドル内の framework で見分ける（Electron アプリの bundle id は列挙できない）。
  private static func restoreDelay(for app: NSRunningApplication?) -> Int {
    guard let app else { return restoreDelayMilliseconds }
    if let identifier = app.bundleIdentifier, asyncConsumerBundleIdentifiers.contains(identifier) {
      return asyncConsumerRestoreDelayMilliseconds
    }
    if let bundleURL = app.bundleURL, hasEmbeddedChromium(bundleURL) {
      return asyncConsumerRestoreDelayMilliseconds
    }
    return restoreDelayMilliseconds
  }

  /// Electron / CEF は `Contents/Frameworks` にレンダラのヘルパ（`… Helper.app`）を必ず同梱する。
  static func hasEmbeddedChromium(_ bundleURL: URL) -> Bool {
    let frameworks = bundleURL.appending(path: "Contents/Frameworks")
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
      return false
    }
    return entries.contains { $0.hasSuffix(" Helper.app") }
      || entries.contains("Electron Framework.framework")
      || entries.contains("Chromium Embedded Framework.framework")
  }

  /// 挿入せずにテキストだけ残す（R16 の activate タイムアウト時）。promise ではなく実データを置く。
  @MainActor
  /// 戻り値は本文を置けたか。置けなければ通知で「クリップボードにあります」と言わない。
  @discardableResult
  func copyToClipboard(text: String) -> Bool {
    let pasteboard = generalPasteboard
    let expectedChangeCount = pasteboard.changeCount
    guard
      ClipboardSafety.canMutate(
        expectedChangeCount: expectedChangeCount, currentChangeCount: pasteboard.changeCount)
    else { return false }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return true
  }

  /// `⌃` / `⇧` / `⌥` の物理状態が空くまで待つ。押されていなければ 0 を返して即返る。
  /// HID state だけを見ることで、自分が post した Cmd+V の flags を物理入力と誤認しない。
  private static func waitForModifierRelease() async -> Double {
    guard Self.modifiersHeld() else { return 0 }
    let start = voxNowMilliseconds()
    let deadline = start + Self.modifierReleaseTimeoutMilliseconds
    // VoxPoll.wait checks before sleeping; this wait must sleep first to keep the
    // original timing this measurement (modifierWaitMilliseconds) was calibrated against.
    while voxNowMilliseconds() < deadline {
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        break
      }
      if !Self.modifiersHeld() { break }
    }
    return voxNowMilliseconds() - start
  }

  private static func modifiersHeld() -> Bool {
    let watched: CGEventFlags = [.maskControl, .maskShift, .maskAlternate]
    return !CGEventSource.flagsState(.hidSystemState).isDisjoint(with: watched)
  }

  private static func returnModifiersHeld() -> Bool {
    let watched = returnModifierMask
    return !CGEventSource.flagsState(.hidSystemState).isDisjoint(with: watched)
  }

  private static let returnModifierMask: CGEventFlags = [
    .maskCommand, .maskControl, .maskShift, .maskAlternate, .maskSecondaryFn
  ]

  /// Modifier-only diagnostics. Never records key codes, characters, or unrecognized flag bits.
  private static func logReturnModifierState() {
    let hardware = CGEventSource.flagsState(.hidSystemState).intersection(returnModifierMask)
    let combined = CGEventSource.flagsState(.combinedSessionState).intersection(returnModifierMask)
    voxLog(
      "auto_enter_modifier_state hardware_names=\(modifierNames(hardware)) "
        + "hardware_mask=\(hardware.rawValue) combined_names=\(modifierNames(combined)) "
        + "combined_mask=\(combined.rawValue)")
  }

  private static func modifierNames(_ flags: CGEventFlags) -> String {
    var names: [String] = []
    if flags.contains(.maskCommand) { names.append("cmd") }
    if flags.contains(.maskControl) { names.append("ctrl") }
    if flags.contains(.maskShift) { names.append("shift") }
    if flags.contains(.maskAlternate) { names.append("opt") }
    if flags.contains(.maskSecondaryFn) { names.append("fn") }
    return names.isEmpty ? "none" : names.joined(separator: ",")
  }

  private static func postReturn() -> Bool {
    guard let source = CGEventSource(stateID: .privateState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
    else { return false }
    down.flags = []
    up.flags = []
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  /// 前面アプリが無応答でも返ってくるように、必ず上限を置いてから聞く（A-2）。
  static func captureTarget(
    processID: Int32, timeout: Float = messagingTimeoutSeconds,
    includeWindow: Bool = false
  ) -> CapturedInjectionTarget {
    let application = AXUIElementCreateApplication(pid_t(processID))
    if AXUIElementSetMessagingTimeout(application, timeout) != .success {
      return CapturedInjectionTarget(
        safetyIdentity: InjectionTarget(processID: processID, focusedElement: .unknown),
        focusedElement: nil)
    }
    let window = includeWindow ? Self.focusedWindow(processID: processID) : nil
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      application, kAXFocusedUIElementAttribute as CFString, &value)
    guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return CapturedInjectionTarget(
        safetyIdentity: InjectionTarget(processID: processID, focusedElement: .unknown),
        focusedElement: nil, focusedWindow: window)
    }
    return CapturedInjectionTarget(
      safetyIdentity: InjectionTarget(processID: processID, focusedElement: .known(1)),
      focusedElement: unsafeDowncast(value, to: AXUIElement.self), focusedWindow: window)
  }

  private static func focusedWindow(processID: Int32) -> AXUIElement? {
    let app = AXUIElementCreateApplication(processID)
    guard AXUIElementSetMessagingTimeout(app, 0.05) == .success else { return nil }
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private static func isSameWindow(as target: CapturedInjectionTarget) -> Bool {
    guard let original = target.focusedWindow,
      let current = focusedWindow(processID: target.safetyIdentity.processID)
    else { return false }
    return CFEqual(original, current)
  }

  /// 拒否の切り分けで確定時の要素も要るので、識別子と一緒に返す。
  private static func currentSafetyTarget(
    for original: CapturedInjectionTarget, timeout: Float = messagingTimeoutSeconds
  ) -> CapturedInjectionTarget {
    let identity = original.safetyIdentity
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.processID else {
      return CapturedInjectionTarget(
        safetyIdentity: InjectionTarget(processID: -1, focusedElement: .unknown),
        focusedElement: nil)
    }
    let current = captureTarget(processID: identity.processID, timeout: timeout)
    let currentFocus: FocusedElementIdentity
    if let expectedElement = original.focusedElement, let actualElement = current.focusedElement {
      currentFocus = CFEqual(expectedElement, actualElement) ? .known(1) : .known(2)
    } else {
      currentFocus = .unknown
    }
    return CapturedInjectionTarget(
      safetyIdentity: InjectionTarget(processID: identity.processID, focusedElement: currentFocus),
      focusedElement: current.focusedElement)
  }

  /// 拒否の条件を切り分けるための 1 行。役割だけを読み、本文・値・タイトルには触れない。
  private static func logRejection(
    _ reason: String, original: CapturedInjectionTarget, current: CapturedInjectionTarget?
  ) {
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
    voxLog(
      "injection_rejected reason=\(reason) frontmost=\(frontmost) "
        + "original_role=\(elementRole(original.focusedElement)) "
        + "current_role=\(elementRole(current?.focusedElement))")
  }

  private static func elementRole(_ element: AXUIElement?) -> String {
    guard let element, AXUIElementSetMessagingTimeout(element, 0.05) == .success else {
      return "-/-"
    }
    return "\(stringAttribute(element, kAXRoleAttribute))"
      + "/\(stringAttribute(element, kAXSubroleAttribute))"
  }

  private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let text = value as? String, !text.isEmpty
    else { return "-" }
    return text
  }

  private static func failure(
    text: String, error: String, modifierWait: Double = 0, clipboardContainsText: Bool = false
  ) -> InjectionOutcome {
    InjectionOutcome(
      pastePostedMilliseconds: voxNowMilliseconds(), pasteReceivedMilliseconds: nil,
      clipboardRestored: false, modifierWaitMilliseconds: modifierWait,
      pastedCharacters: text.count, readbackCharacters: nil,
      clipboardContainsText: clipboardContainsText, pasteVerified: false, error: error,
      pastePosted: false)
  }

  /// 受領証は provideDataForType の中で記録するので、検出のポーリング粒度は
  /// 記録される時刻の精度に影響しない。
  private func waitForReceipt(from postedMilliseconds: Double) async -> Double? {
    await VoxPoll.wait(
      until: { self.lock.withLock { self.receiptMilliseconds } != nil },
      deadline: postedMilliseconds + Self.receiptTimeoutMilliseconds,
      step: .milliseconds(2), now: voxNowMilliseconds)
    return lock.withLock { receiptMilliseconds }
  }

  // MARK: クリップボードの退避と復元

  private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
    guard let items = pasteboard.pasteboardItems else { return [] }
    return items.compactMap { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          copy.setData(data, forType: type)
        }
      }
      return copy.types.isEmpty ? nil : copy
    }
  }

  private static func restore(
    _ items: [NSPasteboardItem], to pasteboard: NSPasteboard, expectedChangeCount: Int
  ) {
    ClipboardSafety.mutateIfOwned(
      expectedChangeCount: expectedChangeCount, currentChangeCount: pasteboard.changeCount
    ) {
      pasteboard.clearContents()
      if !items.isEmpty { pasteboard.writeObjects(items) }
    }
  }

  // MARK: V の keycode 解決（日本語配列・非 QWERTY 対策。ADR-009）

  private static func pasteKeyCode() -> CGKeyCode {
    let sources = [
      TISCopyCurrentKeyboardLayoutInputSource(),
      TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
    ]
    for source in sources {
      guard let inputSource = source?.takeRetainedValue(),
        let pointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
      else { continue }
      let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
      if let keyCode = keyCode(for: "v", layoutData: data) { return keyCode }
    }
    return 9  // ANSI の V
  }

  private static func keyCode(for character: Character, layoutData: Data) -> CGKeyCode? {
    layoutData.withUnsafeBytes { raw -> CGKeyCode? in
      guard let base = raw.baseAddress else { return nil }
      let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
      let keyboardType = UInt32(LMGetKbdType())
      for candidate in 0..<UInt16(128) {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
          layout,
          candidate,
          UInt16(kUCKeyActionDown),
          0,
          keyboardType,
          OptionBits(kUCKeyTranslateNoDeadKeysBit),
          &deadKeyState,
          characters.count,
          &length,
          &characters
        )
        guard status == noErr, length > 0 else { continue }
        let produced = String(utf16CodeUnits: characters, count: length)
        if produced == String(character) { return CGKeyCode(candidate) }
      }
      return nil
    }
  }
}

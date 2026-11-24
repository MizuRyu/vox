import Foundation

/// Subroles refine an AX role and may legitimately be absent on ordinary text fields.
public enum InputSubroleState: Sendable {
  case missing
  case named(String)
  case failed

  public var allowsTextInspection: Bool {
    switch self {
    case .missing: true
    case .named(let value): value != "AXSecureTextField"
    case .failed: false
    }
  }
}

/// Ephemeral input contents used only to confirm this insertion; never logged or persisted.
public struct TextInsertionSnapshot: Equatable, Sendable {
  public let value: String
  public let selection: NSRange

  public init(value: String, selection: NSRange) {
    self.value = value
    self.selection = selection
  }
}

public struct AutoEnterPlan: Sendable {
  public static let maximumUTF16Length = 65_536
  private let expected: TextInsertionSnapshot

  public init?(before: TextInsertionSnapshot, insertedText: String) {
    let length = before.value.utf16.count
    let insertedLength = insertedText.utf16.count
    let selection = before.selection
    guard !insertedText.isEmpty, length <= Self.maximumUTF16Length,
      insertedLength <= Self.maximumUTF16Length,
      selection.location >= 0, selection.length >= 0,
      selection.location <= length, selection.length <= length - selection.location,
      Self.isUTF16Boundary(selection.location, in: before.value),
      Self.isUTF16Boundary(selection.location + selection.length, in: before.value),
      length - selection.length + insertedLength <= Self.maximumUTF16Length
    else { return nil }
    let value = (before.value as NSString).replacingCharacters(in: selection, with: insertedText)
    // No observable change means no proof that this paste has been processed.
    guard value != before.value else { return nil }
    expected = TextInsertionSnapshot(
      value: value,
      selection: NSRange(location: selection.location + insertedLength, length: 0))
  }

  private static func isUTF16Boundary(_ offset: Int, in value: String) -> Bool {
    let units = Array(value.utf16)
    guard offset > 0, offset < units.count else { return true }
    return !(0xDC00...0xDFFF).contains(units[offset])
      || !(0xD800...0xDBFF).contains(units[offset - 1])
  }

  public func matches(_ snapshot: TextInsertionSnapshot) -> Bool { snapshot == expected }
}

public enum AutoEnterResult: String, Sendable {
  case disabled, posted, postedUnverified, unverifiable, inputUnavailable, readbackMismatch,
    timedOut, invalidClock, targetChanged, windowUnverified,
    modifiersHeld, cancelled, clipboardChanged, eventUnavailable

  public var isVerifiedInsertion: Bool { self == .posted }
}

/// 自動 Enter の判断に使う、外から差し込む観測と作用。一致を確かめて送るかどうかで読むものが違う
/// （`sameWindow` は一致を確かめずに送るときだけが見る）。
@MainActor
public struct AutoEnterProbes {
  public let currentTarget: () -> InjectionTarget
  public let modifiersHeld: () -> Bool
  public let isCancelled: () -> Bool
  public let clipboardOwned: () -> Bool
  public let readback: () -> TextInsertionSnapshot?
  public let sameWindow: () -> Bool
  public let postReturn: () -> Bool
  public let now: () -> Double
  public let wait: () async -> Void

  public init(
    currentTarget: @escaping () -> InjectionTarget, modifiersHeld: @escaping () -> Bool,
    isCancelled: @escaping () -> Bool, clipboardOwned: @escaping () -> Bool,
    readback: @escaping () -> TextInsertionSnapshot?, sameWindow: @escaping () -> Bool,
    postReturn: @escaping () -> Bool, now: @escaping () -> Double,
    wait: @escaping () async -> Void
  ) {
    self.currentTarget = currentTarget
    self.modifiersHeld = modifiersHeld
    self.isCancelled = isCancelled
    self.clipboardOwned = clipboardOwned
    self.readback = readback
    self.sameWindow = sameWindow
    self.postReturn = postReturn
    self.now = now
    self.wait = wait
  }
}

public enum AutoEnterGate {
  /// 一致を確かめずに送るとき、貼り付けから Enter までおく間。一致が先に取れれば待たない。
  static let unverifiedDelaySeconds = 0.5

  /// ADR-025。ターミナルは画面全体を読めるが、貼った本文との一致は取れない。読み返せないアプリとして扱う。
  /// 表はパレットの対象判定（`PaletteTargetAdapter`）と共有する。
  public static func readsBack(bundleIdentifier: String?) -> Bool {
    PaletteTargetAdapter.forBundleIdentifier(bundleIdentifier) != .terminal
  }

  /// 読み返しが一致すれば、すぐに Return を打つ。一致しない・読めないときは `sendWhenUnverified` が
  /// 送るかを決め、猶予が過ぎた時点で他の拒否理由（取り消し・ウィンドウ変化など）がなければ打つ。
  /// ADR-035。読めることで、読めない入力欄より送られにくくしない（貼った本文を組み替える入力欄は、
  /// 読めても一致しない）。
  @MainActor
  public static func run(
    enabled: Bool, sendWhenUnverified: Bool, readsBack: Bool = true, plan: AutoEnterPlan?,
    original: InjectionTarget, pastePostedAt: Double, probes: AutoEnterProbes
  ) async -> AutoEnterResult {
    guard enabled else { return .disabled }
    // 計画があるなら貼り付け前に読めている。無いときだけ入力欄に聞く。
    let readable = readsBack && (plan != nil || probes.readback() != nil)
    guard readable || sendWhenUnverified else { return .unverifiable }
    var matchable = false
    if readable, plan != nil, case .known = original.focusedElement { matchable = true }
    guard matchable || sendWhenUnverified else { return .inputUnavailable }
    let startedAt: Double
    let deadlineSeconds: Double
    let attempts: Int
    // 期限切れの言い方。一致だけで送る側は入力欄を一度も読めなければ「読めない」と言う。
    var expiry = AutoEnterResult.timedOut
    if sendWhenUnverified {
      // 一致を確かめずに送る側は時計の異常を rejection() の中でだけ見る
      // （取り消しなど他の理由が先に立てば、その理由を優先する）。
      startedAt = pastePostedAt
      deadlineSeconds = 2.0
      attempts = 100
    } else {
      // A receipt is deliberately absent from this branch: only matching input readback can permit Return.
      startedAt = probes.now()
      guard startedAt.isFinite else { return .invalidClock }
      deadlineSeconds = 1.5
      attempts = 75
      expiry = .inputUnavailable
    }
    func elapsed() -> Double { probes.now() - startedAt }
    func rejection(
      checkModifiers: Bool = true, checkDeadline: Bool = true, unverified: Bool = !matchable
    ) -> AutoEnterResult? {
      if probes.isCancelled() { return .cancelled }
      if !InjectionSafety.canPost(to: original, current: probes.currentTarget(), modifiersHeld: false) {
        return .targetChanged
      }
      if unverified, !probes.sameWindow() { return .windowUnverified }
      if checkModifiers, probes.modifiersHeld() { return .modifiersHeld }
      if !probes.clipboardOwned() { return .clipboardChanged }
      let seconds = elapsed()
      if !seconds.isFinite || seconds < 0 { return .invalidClock }
      if checkDeadline, seconds >= deadlineSeconds { return expiry }
      return nil
    }
    /// 一致を確かめて押せるかを 1 回試す。`nil` は「まだ待つ」。
    func verifiedAttempt() -> AutoEnterResult? {
      guard let plan, let snapshot = probes.readback() else { return nil }
      expiry = .timedOut
      guard plan.matches(snapshot) else { return nil }
      if let reason = rejection() { return reason }
      // Re-read immediately before posting to catch edits or cursor movement during the first read.
      // 一致を確かめずに送る設定では、食い違いで打ち切らず猶予を待つ。
      guard let last = probes.readback() else { return sendWhenUnverified ? nil : .inputUnavailable }
      guard plan.matches(last) else { return sendWhenUnverified ? nil : .readbackMismatch }
      if let reason = rejection() { return reason }
      return probes.postReturn() ? .posted : .eventUnavailable
    }
    /// 押せるかを 1 回試す。`nil` は「まだ待つ」。
    func attempt() -> AutoEnterResult? {
      if matchable, let result = verifiedAttempt() { return result }
      guard sendWhenUnverified, elapsed() >= unverifiedDelaySeconds else { return nil }
      if let reason = rejection(unverified: true) { return reason }
      return probes.postReturn() ? .postedUnverified : .eventUnavailable
    }
    // Both a deadline and an attempt bound cover a stalled clock or test scheduler.
    for _ in 0..<attempts {
      if let reason = rejection(checkModifiers: false, checkDeadline: false) { return reason }
      if probes.modifiersHeld() {
        if elapsed() >= deadlineSeconds { return .modifiersHeld }
      } else if let result = attempt() {
        return result
      }
      await probes.wait()
    }
    if let reason = rejection(checkModifiers: false, checkDeadline: false) { return reason }
    if probes.modifiersHeld() { return .modifiersHeld }
    return expiry
  }
}

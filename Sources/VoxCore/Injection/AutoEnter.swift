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

  public var notice: String? {
    switch self {
    case .disabled, .posted, .postedUnverified: nil
    case .unverifiable: "貼り付けた内容を確認できないアプリのため、Enterは押していません"
    case .inputUnavailable: "貼り付けた内容を確認できなかったため、Enterは押していません"
    case .readbackMismatch: "貼り付け後に入力欄が変わったため、Enterは押していません"
    case .timedOut: "貼り付けを時間内に確認できなかったため、Enterは押していません"
    case .invalidClock: "待ち時間を測れなかったため、Enterは押していません"
    case .windowUnverified: "元のウィンドウを確認できなかったため、Enterは押していません"
    case .targetChanged: "貼り付け先が変わったため、Enterは押していません"
    case .modifiersHeld: "修飾キーが押されたままだったため、Enterは押していません"
    case .cancelled: "Enterを取り消しました"
    case .clipboardChanged: "クリップボードが変わったため、Enterは押していません"
    case .eventUnavailable: "Enterを押せませんでした"
    }
  }
}

/// 自動 Enter の判断に使う、外から差し込む観測と作用。読み返せる入力欄かどうかで読むものが違う
/// （`sameWindow` は読み返せないときだけが見る）。
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
  /// 読み返せない入力欄で貼り付けから Enter までおく間。読み返せる側は一致の確認がこれに代わる。
  static let unverifiedDelaySeconds = 0.5

  /// 読み返せる入力欄では読み返しの一致だけが Return を許可する。読み返せない入力欄では
  /// `sendWhenUnverified` が送るかを決め、猶予が過ぎた時点で他の拒否理由（取り消し・
  /// ウィンドウ変化など）がなければ打つ。
  @MainActor
  public static func run(
    enabled: Bool, sendWhenUnverified: Bool, plan: AutoEnterPlan?, original: InjectionTarget,
    pastePostedAt: Double, probes: AutoEnterProbes
  ) async -> AutoEnterResult {
    guard enabled else { return .disabled }
    // 計画があるなら貼り付け前に読めている。無いときだけ入力欄に聞く。
    let verifying = plan != nil || probes.readback() != nil
    guard verifying || sendWhenUnverified else { return .unverifiable }
    let startedAt: Double
    let deadlineSeconds: Double
    let attempts: Int
    // 期限切れの言い方。読み返せる側は入力欄を一度も読めなければ「読めない」と言う。
    var expiry = AutoEnterResult.timedOut
    if verifying {
      // A receipt is deliberately absent from this branch: only matching input readback can permit Return.
      guard plan != nil, case .known = original.focusedElement else { return .inputUnavailable }
      startedAt = probes.now()
      guard startedAt.isFinite else { return .invalidClock }
      deadlineSeconds = 1.5
      attempts = 75
      expiry = .inputUnavailable
    } else {
      // 読み返せない側は時計の異常を rejection() の中でだけ見る
      // （取り消しなど他の理由が先に立てば、その理由を優先する）。
      startedAt = pastePostedAt
      deadlineSeconds = 2.0
      attempts = 100
    }
    func elapsed() -> Double { probes.now() - startedAt }
    func rejection(checkModifiers: Bool = true, checkDeadline: Bool = true) -> AutoEnterResult? {
      if probes.isCancelled() { return .cancelled }
      if !InjectionSafety.canPost(to: original, current: probes.currentTarget(), modifiersHeld: false) {
        return .targetChanged
      }
      if !verifying, !probes.sameWindow() { return .windowUnverified }
      if checkModifiers, probes.modifiersHeld() { return .modifiersHeld }
      if !probes.clipboardOwned() { return .clipboardChanged }
      let seconds = elapsed()
      if !seconds.isFinite || seconds < 0 { return .invalidClock }
      if checkDeadline, seconds >= deadlineSeconds { return expiry }
      return nil
    }
    /// 押せるかを 1 回試す。`nil` は「まだ待つ」。
    func attempt() -> AutoEnterResult? {
      guard verifying else {
        guard elapsed() >= unverifiedDelaySeconds else { return nil }
        if let reason = rejection() { return reason }
        return probes.postReturn() ? .postedUnverified : .eventUnavailable
      }
      guard let plan, let snapshot = probes.readback() else { return nil }
      expiry = .timedOut
      guard plan.matches(snapshot) else { return nil }
      if let reason = rejection() { return reason }
      // Re-read immediately before posting to catch edits or cursor movement during the first read.
      guard let last = probes.readback() else { return .inputUnavailable }
      guard plan.matches(last) else { return .readbackMismatch }
      if let reason = rejection() { return reason }
      return probes.postReturn() ? .posted : .eventUnavailable
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

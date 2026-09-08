// 貼り付けを実行してよいかの判定。入力先の同一性、クリップボードの所有、修飾キー、
// そして受け取った結果を認識の世代で選り分けるところまで。

import Foundation

public enum FocusedElementIdentity: Equatable, Sendable {
  case known(UInt64)
  case unknown
}

public struct InjectionTarget: Equatable, Sendable {
  public let processID: Int32
  public let focusedElement: FocusedElementIdentity

  public init(processID: Int32, focusedElement: FocusedElementIdentity) {
    self.processID = processID
    self.focusedElement = focusedElement
  }
}

/// 貼り付けを中止した条件。raw value は計測・履歴の `error` にそのまま入る。
public enum InjectionRejection: String, Sendable, Equatable {
  case modifiersHeld = "modifier_release_timeout"
  case processChanged = "input_target_changed_process"
  case focusedElementChanged = "input_target_changed_focus"
  case focusedElementUnreadable = "input_target_changed_focus_unreadable"
}

public enum InjectionSafety {
  /// Unknown AX identity preserves compatibility with apps that do not expose a focused element.
  /// In that case this can only guarantee that the process remains the same.
  public static func rejection(
    posting original: InjectionTarget, current: InjectionTarget, modifiersHeld: Bool
  ) -> InjectionRejection? {
    if modifiersHeld { return .modifiersHeld }
    guard original.processID == current.processID else { return .processChanged }
    switch (original.focusedElement, current.focusedElement) {
    case (.known(let originalID), .known(let currentID)):
      return originalID == currentID ? nil : .focusedElementChanged
    case (.unknown, _):
      return nil
    case (.known, .unknown):
      return .focusedElementUnreadable
    }
  }

  public static func canPost(
    to original: InjectionTarget, current: InjectionTarget, modifiersHeld: Bool
  ) -> Bool {
    rejection(posting: original, current: current, modifiersHeld: modifiersHeld) == nil
  }
}

public struct InjectionAttempt: Sendable {
  private let original: InjectionTarget

  public init(original: InjectionTarget) { self.original = original }

  public func checkTarget(current: InjectionTarget) -> Bool {
    InjectionSafety.canPost(to: original, current: current, modifiersHeld: false)
  }

  public func readyToPost(
    current: InjectionTarget, modifiersHeld: Bool, cancelled: Bool
  ) -> Bool {
    !cancelled
      && InjectionSafety.canPost(
        to: original, current: current, modifiersHeld: modifiersHeld)
  }
}

public enum InjectionOrchestrationResult: Sendable, Equatable {
  case posted
  /// 理由が nil のときはキャンセル。
  case rejected(InjectionRejection?)
}

public enum InjectionOrchestrator {
  @MainActor
  public static func run(
    original: InjectionTarget,
    currentTarget: () -> InjectionTarget,
    modifiersHeld: () -> Bool,
    isCancelled: () -> Bool,
    waitForModifierRelease: () async -> Void,
    prepareToPost: () -> Void,
    postEvent: () -> Void
  ) async -> InjectionOrchestrationResult {
    func rejected(modifiersHeld: Bool) -> InjectionOrchestrationResult? {
      if isCancelled() { return .rejected(nil) }
      guard
        let reason = InjectionSafety.rejection(
          posting: original, current: currentTarget(), modifiersHeld: modifiersHeld)
      else { return nil }
      return .rejected(reason)
    }
    if let result = rejected(modifiersHeld: false) { return result }
    await waitForModifierRelease()
    if let result = rejected(modifiersHeld: modifiersHeld()) { return result }
    prepareToPost()
    if let result = rejected(modifiersHeld: modifiersHeld()) { return result }
    postEvent()
    return .posted
  }
}

public enum ClipboardSafety {
  public static func canMutate(expectedChangeCount: Int, currentChangeCount: Int) -> Bool {
    expectedChangeCount == currentChangeCount
  }

  @discardableResult
  public static func mutateIfOwned(
    expectedChangeCount: Int, currentChangeCount: Int, _ mutation: () -> Void
  ) -> Bool {
    guard canMutate(
      expectedChangeCount: expectedChangeCount, currentChangeCount: currentChangeCount)
    else { return false }
    mutation()
    return true
  }
}

public enum PasteEvidence: Sendable {
  case requested
  case receipt
  case verified

  public var isVerifiedInsertion: Bool {
    if case .verified = self { return true }
    return false
  }
}

public enum HistoryInsertionStatus {
  public static func text(verified: Bool) -> String {
    verified ? "挿入確認済み" : "挿入未確認"
  }
}

public struct RecognitionGeneration: Equatable, Sendable {
  fileprivate let value: UInt64
}

public struct RecognitionLifecycle: Sendable {
  private var nextValue: UInt64 = 0
  private var active: RecognitionGeneration?

  public init() {}

  public mutating func begin() -> RecognitionGeneration {
    nextValue &+= 1
    let generation = RecognitionGeneration(value: nextValue)
    active = generation
    return generation
  }

  public func accepts(_ generation: RecognitionGeneration) -> Bool {
    active == generation
  }

  public mutating func abort(_ generation: RecognitionGeneration) {
    if active == generation { active = nil }
  }

  public mutating func finish(_ generation: RecognitionGeneration) {
    abort(generation)
  }
}

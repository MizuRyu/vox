/// Window presentation decisions kept independent of AppKit and audio resources.
public struct SettingsPresentationState: Sendable {
  public enum Phase: Sendable { case idle, starting, recording, finishing }
  public enum FocusDestination: Sendable { case none, hud, palette }
  private var phase = Phase.idle
  private var pendingShow = false

  public init() {}

  public mutating func requestShow() -> Bool {
    guard phase != .finishing else {
      pendingShow = true
      return false
    }
    return true
  }

  public mutating func transition(to phase: Phase) -> Bool {
    self.phase = phase
    guard phase == .idle, pendingShow else { return false }
    pendingShow = false
    return true
  }

  public func focusAfterClosing(paletteOpen: Bool, textEntryEnabled: Bool) -> FocusDestination {
    guard phase == .starting || phase == .recording else { return .none }
    if paletteOpen { return .palette }
    return textEntryEnabled ? .hud : .none
  }
}

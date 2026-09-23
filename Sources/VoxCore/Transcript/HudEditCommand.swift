// HUD の本文で効かせる ⌘ の編集キー。HUD は自分の first responder へ直接送る
// （アプリが active でない間は main menu のキー等価が届かない疑いがあるため）。
// Edit メニューは残す。⌘, ⌘Q ⌘W はここに入れず、メニューのままにする。

public enum HudEditCommand: String, CaseIterable, Sendable {
  case paste, copy, cut, selectAll, undo, redo

  /// 送る action の selector 名。
  public var actionName: String { rawValue + ":" }

  /// 修飾キーは ⌘（redo だけ ⌘⇧）で、他が混ざれば扱わない。
  public init?(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
    guard command, !option, !control else { return nil }
    switch (key.lowercased(), shift) {
    case ("v", false): self = .paste
    case ("c", false): self = .copy
    case ("x", false): self = .cut
    case ("a", false): self = .selectAll
    case ("z", false): self = .undo
    case ("z", true): self = .redo
    default: return nil
    }
  }
}

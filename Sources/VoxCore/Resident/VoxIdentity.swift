// bundle identifier の正本は Resources/App/Info.plist。Swift 側の写しはここだけで、
// 常駐対象の除外と診断ログの subsystem が同じ値を見る。IdentityTests が plist との一致を固定する。

import Foundation

public enum VoxIdentity {
  public static let bundleIdentifier = "local.vox.app"
}

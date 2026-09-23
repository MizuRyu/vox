// メニューバー項目の位置と可視性は OS が決める（Vox は矩形を計算しない）。
// 画面外に置かれた回を後から確かめるための診断行を組み立てる。

import Foundation

public enum StatusItemDiagnostics {
  public struct Rect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  /// `reason` は測った契機。項目の矩形がどの画面とも重ならない回を `on_screen=false` として残す。
  public static func framesLine(
    reason: String, visible: Bool, button: Rect?, screens: [Rect]
  ) -> String {
    let list = screens.isEmpty ? "-" : screens.map(describe).joined(separator: ";")
    let head = "status_item_frames reason=\(reason) visible=\(visible)"
    guard let button else {
      return "\(head) button=- on_screen=unknown screens=\(list)"
    }
    let onScreen = screens.contains { overlaps(button, $0) }
    return "\(head) button=\(describe(button)) on_screen=\(onScreen) screens=\(list)"
  }

  private static func describe(_ rect: Rect) -> String {
    String(format: "{%.1f,%.1f,%.1f,%.1f}", rect.x, rect.y, rect.width, rect.height)
  }

  private static func overlaps(_ rect: Rect, _ other: Rect) -> Bool {
    rect.x < other.x + other.width && other.x < rect.x + rect.width
      && rect.y < other.y + other.height && other.y < rect.y + rect.height
  }
}

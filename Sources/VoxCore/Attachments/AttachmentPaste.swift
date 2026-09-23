// HUD の ⌘V で画像を保存するかの判定（ADR-017 の決定 1・2）。
// テキストが載っている pasteboard は横取りしない（T20 からの規則。本文を壊さない側を選ぶ）。
// ファイル URL も保存しない。既にあるファイルのパスをそのまま入れる。

import Foundation

public enum AttachmentPaste {
  private static let textTypes: Set<String> = [
    "public.utf8-plain-text", "public.rtf", "com.apple.flat-rtfd", "public.html"
  ]
  private static let fileURLType = "public.file-url"

  /// テキストかファイルが載っているか。載っていれば画像には触らない。
  public static func carriesTextOrFiles(availableTypes: [String]) -> Bool {
    let types = Set(availableTypes)
    return !types.isDisjoint(with: textTypes) || types.contains(fileURLType)
  }

  /// 保存すべき画像の形式。保存しないときは nil。
  public static func imageKind(availableTypes: [String]) -> AttachmentImageKind? {
    guard !carriesTextOrFiles(availableTypes: availableTypes) else { return nil }
    let types = Set(availableTypes)
    return AttachmentImageKind.allCases.first { types.contains($0.pasteboardType) }
  }
}

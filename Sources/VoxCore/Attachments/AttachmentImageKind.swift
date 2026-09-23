// 貼った画像を保存するときの形式（ADR-017）。バイト列は再エンコードせずそのまま書くので、
// ここが持つのは pasteboard の型名・拡張子・受け入れる大きさだけ。
// why: 型名の文字列は AppKit の `NSPasteboard.PasteboardType` の rawValue と一致していなければ
// ならない。VoxCore は AppKit を持てないため、一致は VoxAppTests が突き合わせる。

import Foundation

public enum AttachmentImageKind: String, CaseIterable, Sendable {
  /// 並びは選ぶ優先順（png が最優先）。
  case png, jpeg, heic, gif, tiff

  /// 1 枚の上限。これを超える画像は保存しない。
  public static let maximumBytes = 32 * 1024 * 1024

  public var pasteboardType: String {
    switch self {
    case .png: "public.png"
    case .jpeg: "public.jpeg"
    case .heic: "public.heic"
    case .gif: "com.compuserve.gif"
    case .tiff: "public.tiff"
    }
  }

  public var fileExtension: String {
    switch self {
    case .png: "png"
    case .jpeg: "jpg"
    case .heic: "heic"
    case .gif: "gif"
    case .tiff: "tiff"
    }
  }

  /// 空でも上限超えでもない大きさだけを受ける。断った画像はパスを本文に入れない。
  public static func accepts(byteCount: Int) -> Bool {
    byteCount > 0 && byteCount <= maximumBytes
  }
}

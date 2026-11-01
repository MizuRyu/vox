// R14「割り込み」の追記規則。音声の final は committed の末尾に追記し、
// ユーザーが打った文字は caret 位置に入る（そちらは NSTextView 側の既定動作）。
//
// ここで決めるのは「末尾に追記したとき caret をどうするか」だけ。
// caret が末尾にあれば追従し、途中にあれば動かさない。UI から切り離してテストできるようにする。

import Foundation

/// 追記後のテキストと caret 位置（どちらも UTF-16 オフセット。NSTextView の NSRange に合わせる）。
public struct TranscriptAppend: Equatable, Sendable {
  public let text: String
  public let caret: Int

  public init(text: String, caret: Int) {
    self.text = text
    self.caret = caret
  }
}

public enum TranscriptCaret {
  /// 保留した挿入位置を、先に反映した編集の後ろへ追従させる。
  public static func rebased(_ location: Int, by change: (range: NSRange, text: String)) -> Int {
    guard location >= change.range.location else { return location }
    let insertedLength = (change.text as NSString).length
    if location >= NSMaxRange(change.range) {
      return location + insertedLength - change.range.length
    }
    return change.range.location + insertedLength
  }

  /// 共通の前後を残し、変わった範囲だけを置換する。書記素の途中では区切らない。
  public static func replacement(current: String, desired: String) -> (range: NSRange, text: String)? {
    guard !current.utf16.elementsEqual(desired.utf16) else { return nil }
    let currentLength = (current as NSString).length
    let desiredLength = (desired as NSString).length
    var prefix = 0
    for (left, right) in zip(current, desired) {
      guard left.unicodeScalars.elementsEqual(right.unicodeScalars) else { break }
      prefix += left.utf16.count
    }
    var suffix = 0
    for (left, right) in zip(current.reversed(), desired.reversed()) {
      guard left.unicodeScalars.elementsEqual(right.unicodeScalars),
        prefix + suffix + left.utf16.count <= min(currentLength, desiredLength)
      else { break }
      suffix += left.utf16.count
    }
    let range = NSRange(location: prefix, length: currentLength - prefix - suffix)
    let text = (desired as NSString).substring(with: NSRange(location: prefix, length: desiredLength - prefix - suffix))
    return (range, text)
  }

  /// `text` の末尾に `suffix` を足す。`caret` が末尾なら新しい末尾へ動かし、途中なら据え置く。
  /// `caret` が範囲外のときは末尾に丸める。
  public static func append(_ suffix: String, to text: String, caret: Int) -> TranscriptAppend {
    let length = (text as NSString).length
    let appended = text + suffix
    let appendedLength = (appended as NSString).length
    guard !suffix.isEmpty else {
      return TranscriptAppend(text: text, caret: min(max(0, caret), length))
    }
    if caret >= length {
      return TranscriptAppend(text: appended, caret: appendedLength)
    }
    return TranscriptAppend(text: appended, caret: max(0, caret))
  }

  /// テキストビューの内容 `current` に対し、モデルの `desired` が末尾追記かどうか。
  /// 追記なら足すべき差分を返す。ユーザーが途中を編集して分岐している場合は nil
  /// （その場合ビューには触らない。打った内容を消さないため）。
  public static func pendingSuffix(current: String, desired: String) -> String? {
    guard desired != current, desired.hasPrefix(current) else { return nil }
    return String(desired.dropFirst(current.count))
  }
}

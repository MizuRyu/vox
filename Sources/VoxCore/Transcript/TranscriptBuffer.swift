// T11 / T17 / T18 / T20 / T21。HUD の本文は 1 本のテキストで、3 つの区画が**時間順**に並ぶ。
//
//   head（通常色・編集可） + tentative（淡色・読み取り専用） + tail（通常色・編集可）
//
// T21 の裁定。鍵となる観察は「淡色が出ている時に打ったなら、その音声は打鍵より前に発話されている」。
// だから合流時に音声を打った文字の**前**に入れるのが時間順であり、そうすれば
// **打った文字は一度も動かない**。T17〜T20 はここを取り違えて 3 回並びを変えていた。
//
// - `head`: 淡色より前に確定したもの（音声の final と、それ以前に打った文字）
// - `tentative`: いま出ている淡色（常に 1 つ。区画の真ん中にいる）
// - `tail`: **淡色が出た後に打った文字**
//
// 遷移は 3 つだけ:
// 1. 淡色の更新は `[headEnd, tentativeEnd)` の差し替え。`head` も `tail` も動かない
// 2. 淡色が空 → 非空になるときだけ `head += tail`（打った文字は「その後に喋った音声」より前に確定）
// 3. 確定は `head += final` で淡色を空にする。`tail` は 1 文字も動かない
//
// オフセットはすべて UTF-16（NSTextView の NSRange に合わせる）で、
// 全文（3 区画を連結したもの）を基準に数える。
// caret は編集可能域、すなわち `0...headEnd` か `tentativeEnd...length` にしか置けない。

import Foundation

public struct TranscriptBuffer: Equatable, Sendable {
  /// 淡色より前に確定した分。音声の final と、それ以前に打った文字（T21 で `committed` から改名）。
  public private(set) var head: String
  /// いま出ている淡色。区画の真ん中にある（T20 までは末尾だった）。
  public private(set) var tentative: String
  /// 淡色が**出た後に**打った文字（T21 で `trailing` から改名。意味も「淡色の前」から反転した）。
  public private(set) var tail: String
  public private(set) var caret: Int

  /// `caret` に nil を渡すと全体の末尾（= `tail` の末尾）に置く。
  public init(head: String = "", tentative: String = "", tail: String = "", caret: Int? = nil) {
    self.head = head
    self.tentative = tentative
    self.tail = tail
    let length =
      (head as NSString).length + (tentative as NSString).length + (tail as NSString).length
    self.caret = length
    self.caret = clampCaret(caret ?? length)
  }

  /// `head` の終端であり、淡色域の始まり。
  public var headEnd: Int { (head as NSString).length }

  /// 淡色域の終端であり、`tail` の始まり。ここが「淡色が出た後に打った文字」の先頭。
  public var tentativeEnd: Int { headEnd + (tentative as NSString).length }

  /// テキストビューに見えている全文。
  public var text: String { head + tentative + tail }

  public var length: Int { tentativeEnd + (tail as NSString).length }

  /// 淡色域の差し替え。`head` も `tail` も動かない（打っている最中に淡色が伸び縮みしても
  /// 打った文字は 1 文字も動かない。T21 の主目的）。
  ///
  /// 淡色が空から非空に変わるとき（新しい淡色が始まるとき）だけ、先に `head += tail` して
  /// `tail` を空にする。打鍵はその後に喋った音声より前に起きているので、これが時間順。
  ///
  /// caret は
  /// - 全体の末尾なら新しい末尾（淡色の後ろ。次に打つ位置）
  /// - `tail` 内なら同じ文字の上（淡色の伸び縮み分だけずらす）
  /// - `head` 内なら動かさない
  public mutating func applyTentative(_ text: String) {
    let wasAtTail = caret >= length
    if tentative.isEmpty, !text.isEmpty, !tail.isEmpty {
      head += tail
      tail = ""
    }
    let previousEnd = tentativeEnd
    let delta = (text as NSString).length - (tentative as NSString).length
    tentative = text
    if wasAtTail {
      caret = length
    } else if caret >= previousEnd {
      caret = clampCaret(caret + delta)
    }
  }

  /// final の到着（T21）。`head += final` として淡色を空にする。**`tail` は動かさない**。
  /// 淡色がその場で通常色に変わるだけで、打った文字は 1 文字も動かない。
  ///
  /// caret は
  /// - `head` の途中なら動かさない
  /// - 淡色の直前（`headEnd`）なら新しい `headEnd`（= 確定した音声の後ろ。意味を保つ）
  /// - `tail` 側なら同じ文字の上（淡色が final に置き換わった分だけずらす）
  public mutating func commitFinal(_ suffix: String) {
    guard !suffix.isEmpty else { return }
    let wasBeforeTentative = caret == headEnd
    let previousEnd = tentativeEnd
    let delta = (suffix as NSString).length - (tentative as NSString).length
    head += suffix
    tentative = ""
    if wasBeforeTentative {
      caret = headEnd
    } else if caret >= previousEnd {
      caret = clampCaret(caret + delta)
    }
  }

  /// `shouldChangeTextIn` の判定。編集可能域 `[0, headEnd]` と `[tentativeEnd, length]` だけ通す。
  /// 淡色域の内部に掛かる範囲は拒否する。
  ///
  /// T15。IME の変換中は未確定文字列（marked text）が caret 位置に置かれ、
  /// 変換のたびに `[caret, caret + markedLength)` が置き換わる。
  /// buffer 側は変換確定まで更新しない（marked text はどの領域にも入っていない）ので、
  /// この範囲に収まる編集だけ追加で許可する。`markedLength` が 0 なら従来どおり。
  public func canEdit(range: NSRange, markedLength: Int = 0) -> Bool {
    guard range.location >= 0, range.length >= 0 else { return false }
    let end = range.location + range.length
    // 淡色が無いときは全体がひと続きの編集可能域（`head` と `tail` の境目は見えない）。
    if tentative.isEmpty, end <= length { return true }
    if end <= headEnd { return true }
    if range.location >= tentativeEnd, end <= length { return true }
    guard markedLength > 0 else { return false }
    // marked text の起点は caret だが、ビューが先に動いている場合に備えて
    // 編集可能域の境目も起点として許す。
    for anchor in [caret, headEnd, tentativeEnd, length] {
      if range.location >= anchor, end <= anchor + markedLength { return true }
    }
    return false
  }

  /// 打った文字。淡色域の内部なら拒否する。淡色の後ろ（`tail` 側）に打った分は `tail` に入り、
  /// 淡色より前に打った分は `head` に入る（T21。位置と区画が素直に一致する）。
  @discardableResult
  public mutating func insertTyped(_ text: String, at location: Int) -> Bool {
    replace(range: NSRange(location: location, length: 0), with: text)
  }

  /// 選択範囲の置換（削除も含む）。拒否したときは何も変えずに false。
  @discardableResult
  public mutating func replace(range: NSRange, with text: String) -> Bool {
    guard canEdit(range: range) else { return false }
    if tentative.isEmpty {
      // 淡色が無いので `head` と `tail` は地続き。合流させてから 1 本の文字列として編集する。
      head += tail
      tail = ""
      head = (head as NSString).replacingCharacters(in: range, with: text)
    } else if range.location >= tentativeEnd {
      let local = NSRange(location: range.location - tentativeEnd, length: range.length)
      tail = (tail as NSString).replacingCharacters(in: local, with: text)
    } else {
      head = (head as NSString).replacingCharacters(in: range, with: text)
    }
    caret = range.location + (text as NSString).length
    return true
  }

  /// M3 / T13 / T21 のパレット挿入。既定は全体の末尾（`tail` の末尾。次に打つ位置）。
  /// `at` に位置を渡すとそこに入る（`@` を `head` の途中で打った場合）。
  /// 前後の空白は全文を見て決める。
  public mutating func insertPalette(_ value: String, at location: Int? = nil) {
    let plan = PaletteInsertion.insert(value, into: text, at: location ?? length)
    guard !plan.inserted.isEmpty else { return }
    insertTyped(plan.inserted, at: plan.location)
  }

  public mutating func setCaret(_ location: Int) {
    caret = clampCaret(location)
  }

  /// caret を編集可能域に丸める。淡色域の内部を指したら**全体の末尾**に寄せる
  /// （T21: `tail` の末尾が次に打つ自然な位置）。
  public func clampCaret(_ location: Int) -> Int {
    if location <= 0 { return 0 }
    if location <= headEnd { return location }
    if location >= length { return length }
    if location >= tentativeEnd { return location }
    return length
  }

  /// 選択範囲を編集可能域に収める。淡色域に跨る選択は、掛かっている側だけを残す。
  public func clampSelection(_ range: NSRange) -> NSRange {
    let location = clampCaret(max(0, range.location))
    guard range.length > 0 else { return NSRange(location: location, length: 0) }
    let end = location + range.length
    if tentative.isEmpty { return NSRange(location: location, length: min(end, length) - location) }
    if location <= headEnd {
      return NSRange(location: location, length: min(end, headEnd) - location)
    }
    return NSRange(location: location, length: max(0, min(end, length) - location))
  }
}

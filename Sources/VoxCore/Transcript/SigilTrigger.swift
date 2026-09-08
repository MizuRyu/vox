// T13。HUD のテキスト領域に打った `@` をパレットの合図として解釈する。
// `shouldChangeTextIn` から呼ぶ判定だけをここに置き、AppKit には依存しない。
//
// `@` を文字として入れたいときの逃げ道は `⌥`（option 付きはそのまま通す）。
// 録音中以外は文字としても入れない（`starting` 中に打った `@` が本文に残らないように）。

import Foundation

public enum SigilTriggerDecision: Equatable, Sendable {
  /// パレットを開く。打った文字は入れない。
  case open(PaletteSigil)
  /// そのまま文字として入れる。
  case insertLiteral
  /// 何もしない（文字も入れない）。
  case ignore
}

public enum SigilTrigger {
  /// `replacement` は `shouldChangeTextIn` の `replacementString`。
  /// `enabled` は `--no-sigil-trigger`（false なら常に文字として通す）。
  /// `isComposing` は IME の変換中（marked text がある）。変換の途中経過を合図として食べない。
  public static func classify(
    replacement: String, isRecording: Bool, hasOption: Bool, enabled: Bool = true,
    isComposing: Bool = false
  ) -> SigilTriggerDecision {
    guard enabled, !hasOption, !isComposing else { return .insertLiteral }
    guard replacement.count == 1, let sigil = PaletteSigil(rawValue: replacement) else {
      return .insertLiteral
    }
    return isRecording ? .open(sigil) : .ignore
  }
}

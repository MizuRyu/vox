// A-2 / A-4。tap のコールバックで決める分だけを取り出した判定。
// 何を飲むか、何を起こすかを、AX にもアプリ状態にも触らずに確かめる。

import CoreGraphics
import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Input: ホットキーの判定")
struct HotkeyDecisionTests {
  private func decide(
    keyCode: Int64, flags: CGEventFlags = [], isAutorepeat: Bool = false,
    wantsPalette: Bool = true, wantsEscape: Bool = true
  ) -> HotkeyDecision {
    HotkeyMonitor.decide(
      keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat, toggle: .commandShiftSpace,
      palette: .controlP, wantsPalette: wantsPalette, wantsEscape: wantsEscape)
  }

  @Test("トグル・パレット・esc はそれぞれの出来事になる")
  func matchedKeysBecomeEvents() {
    #expect(
      decide(
        keyCode: HotkeyBinding.commandShiftSpace.keyCode, flags: [.maskCommand, .maskShift])
        == .toggle, "トグルの打鍵が出来事にならない")
    #expect(
      decide(keyCode: HotkeyBinding.controlP.keyCode, flags: [.maskControl]) == .palette,
      "パレットの打鍵が出来事にならない")
    #expect(decide(keyCode: 53) == .escape, "esc が出来事にならない")
  }

  @Test("飲まないと決めた回は素通しする")
  func unmatchedKeysPassThrough() {
    #expect(decide(keyCode: 0) == .pass, "無関係のキーを飲んだ")
    #expect(
      decide(keyCode: HotkeyBinding.controlP.keyCode, flags: [.maskControl], wantsPalette: false)
        == .pass, "録音していないのにパレットのキーを飲んだ")
    #expect(decide(keyCode: 53, wantsEscape: false) == .pass, "HUD が無いのに esc を飲んだ")
    #expect(decide(keyCode: 53, flags: [.maskCommand]) == .pass, "⌘esc を esc として扱った")
  }

  @Test("キーリピートは飲むが出来事にしない（長押しで開始直後に確定しない）")
  func autorepeatIsIgnored() {
    for (keyCode, flags) in [
      (HotkeyBinding.commandShiftSpace.keyCode, CGEventFlags([.maskCommand, .maskShift])),
      (HotkeyBinding.controlP.keyCode, CGEventFlags([.maskControl])),
      (53, CGEventFlags())
    ] {
      #expect(
        decide(keyCode: keyCode, flags: flags, isAutorepeat: true) == .consume,
        "キーリピートを出来事にした key_code=\(keyCode)")
    }
  }
}

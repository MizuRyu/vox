// HUD が自分の first responder へ直接送る編集キー。それ以外（⌘, ⌘Q ⌘W）はメニューに任せる。

import Testing
import VoxCore

@Suite("Transcript: HUD の編集キー")
struct HudEditCommandTests {
  @Test("⌘V ⌘C ⌘X ⌘A ⌘Z ⌘⇧Z が編集の action になる")
  func editKeysMapToActions() {
    let cases: [(String, Bool, HudEditCommand)] = [
      ("v", false, .paste), ("c", false, .copy), ("x", false, .cut),
      ("a", false, .selectAll), ("z", false, .undo), ("z", true, .redo), ("Z", true, .redo)
    ]
    for (key, shift, expected) in cases {
      #expect(
        HudEditCommand(key: key, command: true, shift: shift, option: false, control: false)
          == expected,
        "\(expected) にならない")
    }
    #expect(HudEditCommand.paste.actionName == "paste:", "paste の selector 名が違う")
    #expect(HudEditCommand.selectAll.actionName == "selectAll:", "selectAll の selector 名が違う")
  }

  @Test("メニューの項目と、他の修飾キーの組み合わせは扱わない")
  func otherKeysAreLeftToTheMenu() {
    for key in [",", "q", "w", "p"] {
      #expect(
        HudEditCommand(key: key, command: true, shift: false, option: false, control: false) == nil,
        "⌘\(key) を横取りした")
    }
    #expect(
      HudEditCommand(key: "v", command: false, shift: false, option: false, control: true) == nil,
      "⌃V を横取りした")
    #expect(
      HudEditCommand(key: "v", command: true, shift: false, option: true, control: false) == nil,
      "⌥⌘V を横取りした")
    #expect(
      HudEditCommand(key: "v", command: true, shift: true, option: false, control: false) == nil,
      "⌘⇧V を横取りした")
  }
}

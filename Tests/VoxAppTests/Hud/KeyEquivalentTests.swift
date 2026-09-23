// HUD の ⌘ 編集キー。main menu を通さず、HUD の first responder へ直接届くこと。
// ウィンドウは出さず、キーも送出しない（NSEvent を直に渡す）。

import AppKit
import Foundation
import Testing
@testable import VoxApp

@MainActor
@Suite("Hud: ⌘ 編集キー")
struct KeyEquivalentTests {
  /// why: 表示しないパネルは key になれない。key window の responder chain に頼らずに届くことを見る。
  private func panel(pasteboard: NSPasteboard) throws -> (VoxPanel, TranscriptTextView) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let panel = VoxPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let coordinator = TranscriptEditor.Coordinator(model: HudModel())
    let scrollView = TranscriptEditor.makeScrollView(coordinator: coordinator)
    let textView = try #require(
      scrollView.documentView as? TranscriptTextView, "本文が TranscriptTextView でない")
    textView.pasteboard = pasteboard
    panel.contentView = scrollView
    #expect(panel.makeFirstResponder(textView), "本文が first responder にならない")
    return (panel, textView)
  }

  private func command(_ character: String, in panel: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0),
      "キーイベントを作れない")
  }

  @Test("⌘V は本文の paste に届く")
  func commandVReachesThePaste() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("vox-key-equivalent-paste"))
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/vox-check/a.swift") as NSURL])
    let (panel, textView) = try panel(pasteboard: board)
    #expect(panel.performKeyEquivalent(with: try command("v", in: panel)), "⌘V を処理しなかった")
    // why: ファイル URL をパスに変えるのは TranscriptTextView.paste(_:) だけ（素の NSTextView は何もしない）。
    #expect(textView.string.contains("a.swift"), "paste に届いていない: \(textView.string)")
    expectNoVisibleWindows()
  }

  @Test("⌘A で本文を全選択する")
  func commandASelectsAll() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("vox-key-equivalent-select"))
    let (panel, textView) = try panel(pasteboard: board)
    textView.string = "全選択の検体"
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(panel.performKeyEquivalent(with: try command("a", in: panel)), "⌘A を処理しなかった")
    #expect(
      textView.selectedRange() == NSRange(location: 0, length: (textView.string as NSString).length),
      "全選択になっていない")
    expectNoVisibleWindows()
  }

  @Test("⌘W は HUD で処理せずメニューに任せる")
  func commandWIsLeftToTheMenu() throws {
    let board = NSPasteboard(name: NSPasteboard.Name("vox-key-equivalent-close"))
    let (panel, _) = try panel(pasteboard: board)
    #expect(!panel.performKeyEquivalent(with: try command("w", in: panel)), "⌘W を HUD が処理した")
  }
}

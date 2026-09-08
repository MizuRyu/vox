// HUD 本文のオフスクリーン検証。ウィンドウもキー送出も使わない（旧 vox-hud-check）。

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxApp

@MainActor
@Suite("Hud: 本文の描画と編集の可否")
struct TranscriptEditorTests {
  /// HUD 本文と同じ text system を、有限幅の container 付きで組み立てる。
  private func editor() throws -> (
    model: HudModel, coordinator: TranscriptEditor.Coordinator, textView: NSTextView,
    storage: NSTextStorage
  ) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = HudModel()
    let coordinator = TranscriptEditor.Coordinator(model: model)
    let scrollView = TranscriptEditor.makeScrollView(coordinator: coordinator)
    let textView = try #require(
      scrollView.documentView as? NSTextView, "NSTextView text system is unavailable")
    let storage = try #require(textView.textStorage)
    let container = try #require(textView.textContainer)
    // HUD の本文領域と同程度の有限幅を、認識結果が届く前に layout manager へ与える。
    container.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
    return (model, coordinator, textView, storage)
  }

  /// head + tentative + tail の 3 区画を描かせたところまで進める。
  private func fill(
    _ model: HudModel, _ coordinator: TranscriptEditor.Coordinator, _ textView: NSTextView
  ) {
    model.applyTentative("音声の候補")
    coordinator.sync(textView)
    model.head = "確定済み"
    model.applyTentative("次の候補")
    coordinator.sync(textView)
    // T21。淡色の**後ろ**に打った分（通常色）。tail はテキストビューでの打鍵でしか増えず、
    // モデル側から差分を当てない設計なので、全置換の経路（resetToken）で描かせる。
    model.tail = "打った"
    model.resetToken += 1
    coordinator.sync(textView)
  }

  @Test("3 区画がその色で並び、ウィンドウは開かない")
  func sectionsAreDrawnWithTheirColors() throws {
    let (model, coordinator, textView, storage) = try editor()
    fill(model, coordinator, textView)
    let container = try #require(textView.textContainer)
    let layout = try #require(textView.layoutManager)

    let headLength = (model.head as NSString).length
    let tentativeLength = (model.tentative as NSString).length
    #expect(textView.string == model.head + model.tentative + model.tail, "本文の並びが違う")
    #expect(
      (storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
        .isEqual(NSColor.labelColor) == true, "head が通常色でない")
    // T21。並びは head + tentative + tail。淡色は 3 区画の真ん中。
    #expect(
      (storage.attribute(.foregroundColor, at: headLength, effectiveRange: nil) as? NSColor)?
        .isEqual(NSColor.secondaryLabelColor) == true, "tentative が淡色でない")
    #expect(
      (storage.attribute(
        .foregroundColor, at: headLength + tentativeLength, effectiveRange: nil) as? NSColor)?
        .isEqual(NSColor.labelColor) == true, "tail が通常色でない")
    #expect(
      (storage.attribute(.foregroundColor, at: storage.length - 1, effectiveRange: nil) as? NSColor)?
        .isEqual(NSColor.labelColor) == true, "末尾まで通常色でない")

    layout.ensureLayout(for: container)
    let usedRect = layout.usedRect(for: container)
    #expect(usedRect.width > 0 && usedRect.height > 0, "本文が描かれていない")
    expectNoVisibleWindows()
  }

  @Test("3 区画の組み立ては HudModel が持つ")
  func transcriptCarriesTheThreeSections() throws {
    let (model, coordinator, textView, _) = try editor()
    fill(model, coordinator, textView)
    let transcript = model.transcript
    #expect(transcript.head == model.head, "head が違う")
    #expect(transcript.tentative == model.tentative, "tentative が違う")
    #expect(transcript.tail == model.tail, "tail が違う")
    #expect(transcript.text == textView.string, "全文が描かれている本文と食い違う")
  }

  @Test("淡色の内部への編集は拒否する")
  func editsInsideTheDimTailAreRejected() throws {
    let (model, coordinator, textView, _) = try editor()
    fill(model, coordinator, textView)
    let headLength = (model.head as NSString).length
    // T21。淡色の内部への編集は拒否し、その回を stderr に残す（`edit_rejected …`）。
    #expect(
      coordinator.textView(
        textView, shouldChangeTextIn: NSRange(location: headLength + 1, length: 1),
        replacementString: "x") == false,
      "淡色域への編集を受理した")
  }

  @Test("確定は打った文字を 1 文字も動かさない")
  func commitKeepsTheTypedText() throws {
    let (model, coordinator, textView, storage) = try editor()
    fill(model, coordinator, textView)
    // T21。確定は淡色をその場で置き換えるだけで、並びは head + final + tail のまま。
    model.commitFinal("音声")
    coordinator.sync(textView)
    #expect(textView.string == "確定済み音声" + model.tail, "確定後の並びが違う")
    #expect(model.tail == "打った", "打った文字が変わった")
    let mergedLength = ("確定済み音声" as NSString).length
    #expect(
      (storage.attribute(.foregroundColor, at: mergedLength - 1, effectiveRange: nil) as? NSColor)?
        .isEqual(NSColor.labelColor) == true, "確定した音声が通常色でない")
    #expect(
      (storage.attribute(.foregroundColor, at: mergedLength, effectiveRange: nil) as? NSColor)?
        .isEqual(NSColor.labelColor) == true, "打った文字が通常色でない")
  }

  @Test("ファイルのペーストはパスを差し込み、文字があるときは通常のペーストに任せる")
  func filePasteInsertsThePath() throws {
    let (model, coordinator, textView, storage) = try editor()
    fill(model, coordinator, textView)
    // T20。ユーザーのクリップボードを触らないよう専用の pasteboard で確かめる。
    let root = NSHomeDirectory() + "/vox-hud-check"
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("vox-hud-check-paste"))
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: root + "/Sources/a.swift") as NSURL])
    #expect(
      TranscriptFilePaste.pathText(from: pasteboard, repositoryRoot: root) == "Sources/a.swift",
      "パスを取り出せない")
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: root + "/b.swift") as NSURL, "文字" as NSString])
    #expect(
      TranscriptFilePaste.pathText(from: pasteboard, repositoryRoot: root) == nil,
      "テキストが同時にあるのに横取りした")
    // T21。差し込み位置は全体の末尾（`tail` の末尾）。空白はパレットと同じ規則。
    let insertion = coordinator.filePathInsertion(
      for: "a.swift", selection: NSRange(location: storage.length, length: 0))
    #expect(insertion?.range == NSRange(location: storage.length, length: 0), "差し込み位置が違う")
    #expect(insertion?.text == " a.swift ", "差し込む文字列が違う")
  }

  @Test("SwiftUI の更新が本文に届く")
  func swiftUIUpdateReachesTheTextView() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = HudModel()
    let hostingView = NSHostingView(
      rootView: CheckHost(model: model).frame(width: 320, height: 44))
    hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
    hostingView.layoutSubtreeIfNeeded()
    model.applyTentative("SwiftUI 更新")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    hostingView.layoutSubtreeIfNeeded()
    let textView = try #require(
      descendants(of: hostingView).compactMap { $0 as? NSTextView }.first, "本文が見つからない")
    let container = try #require(textView.textContainer)
    let layout = try #require(textView.layoutManager)
    layout.ensureLayout(for: container)
    let usedRect = layout.usedRect(for: container)
    #expect(textView.string == model.tentative, "SwiftUI の更新が届いていない")
    #expect(usedRect.width > 0 && usedRect.height > 0, "更新後の本文が描かれていない")
  }

  private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
}

private struct CheckHost: View {
  @ObservedObject var model: HudModel

  var body: some View {
    Group {
      if let notice = model.notice {
        Text(notice)
      } else {
        TranscriptEditor(model: model)
          .frame(minHeight: 30)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
  }
}

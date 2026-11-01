// HUD 本文のオフスクリーン検証。ウィンドウもキー送出も使わない（旧 vox-hud-check）。

import AppKit
import Foundation
import SwiftUI
import Testing
import VoxCore
@testable import VoxApp

@MainActor
@Suite("Hud: 本文の描画と編集の可否")
struct TranscriptEditorTests {
  @Test("展開時の高さは全文レイアウトと一致し、画面の半分を超えない")
  func expandedHeightMatchesFullLayout() {
    let texts = [
      "", "音声入力", "確認します。\n", "\n\n\n",
      "👨‍👩‍👧‍👦と絵文字、e\u{301}と日本語を確認します。\n次の行です。",
      String(repeating: "👨‍👩‍👧‍👦🙂\n", count: 30),
      String(repeating: "\tAPI\t入力\n", count: 30),
      String(repeating: "a\u{301}\u{302}\u{303}\n", count: 30),
      String(repeating: "設定を確認してAPIの応答を検証します。\n", count: 40),
      String(repeating: "一二三四五六七八九十", count: 60)
    ]
    for text in texts {
      for width: CGFloat in [120, 320, 680] {
        for visibleHeight: CGFloat in [200, 600, 900] {
          let bounding = NSAttributedString(
            string: text.isEmpty ? " " : text, attributes: TranscriptEditor.committedAttributes
          ).boundingRect(
            with: NSSize(width: max(1, width - 36), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
          let expected = min(visibleHeight / 2, max(132, ceil(bounding.height) + 88))
          #expect(HudPanel.expandedHeight(text: text, width: width, visibleHeight: visibleHeight) == expected)
        }
      }
    }
    expectNoVisibleWindows()
  }

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

  @Test("確定本文の途中を手で編集したあと、音声もその位置に入る")
  func speechFollowsAnEditInsideCommittedText() throws {
    let (model, coordinator, textView, _) = try editor()
    model.head = "前半後半"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    textView.insertText("手", replacementRange: textView.selectedRange())
    coordinator.sync(textView)
    #expect(textView.string == "前半手後半")
    model.applyTentative("音声")
    coordinator.sync(textView)
    #expect(textView.string == "前半手音声後半")
    model.commitFinal("音声。")
    coordinator.sync(textView)
    #expect(textView.string == "前半手音声。後半")
    #expect(textView.selectedRange().location == 6)
    #expect(model.transcript.text == textView.string)
    expectNoVisibleWindows()
  }

  @Test("淡色を経ない確定も、絵文字の後のカーソル位置へ入る")
  func finalOnlySpeechUsesTheCaretAfterAnEmoji() throws {
    let (model, coordinator, textView, _) = try editor()
    model.head = "前🙂後"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 3, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    model.commitFinal("音声")
    coordinator.sync(textView)
    #expect(textView.string == "前🙂音声後")
    #expect(textView.selectedRange().location == 5)
  }

  @Test("途中の淡色は更新位置を保ち、確定後の次の音声は移動したカーソルへ入る")
  func activeSpeechStaysAnchoredUntilTheNextSegment() throws {
    let (model, coordinator, textView, _) = try editor()
    model.head = "左右"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    model.applyTentative("候補")
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    model.applyTentative("音声候補")
    coordinator.sync(textView)
    #expect(textView.string == "左音声候補右")
    #expect(textView.selectedRange().location == 0)
    model.commitFinal("音声")
    model.applyTentative("次")
    coordinator.sync(textView)
    #expect(textView.string == "次左音声右")
    model.commitFinal("次。")
    coordinator.sync(textView)
    #expect(textView.string == "次。左音声右")
  }

  @Test("IME変換中に届いた音声と途中の手入力を両方残す")
  func compositionPreservesQueuedSpeechAndTheExistingSuffix() throws {
    let (model, coordinator, textView, _) = try editor()
    model.head = "前半後半"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    textView.setMarkedText("しゅうせい", selectedRange: NSRange(location: 5, length: 0), replacementRange: textView.selectedRange())
    coordinator.sync(textView)
    #expect(model.isComposing)
    model.commitFinal("音声")
    model.applyTentative("続き")
    textView.insertText("修正", replacementRange: textView.markedRange())
    coordinator.sync(textView)
    #expect(textView.string == "前半修正音声続き後半")
    model.commitFinal("続き。")
    coordinator.sync(textView)
    #expect(textView.string == "前半修正音声続き。後半")
    #expect(model.transcript.text == textView.string)
    #expect(!model.isComposing)
  }

  @Test("途中へ音声を入れながら打った文字を、認識更新と確定で失わない")
  func typingDuringAnInsertedSegmentSurvivesUpdates() throws {
    let (model, coordinator, textView, storage) = try editor()
    model.head = "左右"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    model.applyTentative("声")
    coordinator.sync(textView)
    textView.insertText("手", replacementRange: textView.selectedRange())
    model.applyTentative("音声")
    coordinator.sync(textView)
    #expect(textView.string == "左音声手右")
    model.commitFinal("音声")
    coordinator.sync(textView)
    #expect(textView.string == "左音声手右")
    #expect((storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor) == .labelColor)
    model.applyTentative("次")
    coordinator.sync(textView)
    #expect(textView.string == "左音声手次右")
  }

  @Test("変換中に録音を確定しても、変換した文字と保留した音声を両方残す")
  func resigningTheEditorFlushesCompositionAndSpeech() throws {
    let (model, coordinator, textView, _) = try editor()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = textView.enclosingScrollView
    window.makeFirstResponder(textView)
    model.head = "前半後半"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    textView.setMarkedText("修正", selectedRange: NSRange(location: 2, length: 0), replacementRange: textView.selectedRange())
    coordinator.sync(textView)
    model.commitFinal("音声")
    model.onFinishEditing?()
    window.makeFirstResponder(nil)
    #expect(model.transcript.text == "前半修正音声後半")
    #expect(!model.isComposing)
    #expect(model.typedCharacters == 2)
    expectNoVisibleWindows()
  }

  @Test("認識結果の到着直後に打鍵しても、未描画の音声を失わない")
  func typingImmediatelyAfterRecognitionPreservesSpeech() throws {
    let (model, coordinator, textView, _) = try editor()
    model.head = "前半後半"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    model.commitFinal("音声")
    textView.insertText("手", replacementRange: textView.selectedRange())
    coordinator.sync(textView)
    #expect(textView.string == "前半音声手後半")
    #expect(model.transcript.text == textView.string)
  }

  @Test("変換中の音声とパス挿入は、先に増えた文字に合わせて位置を保つ")
  func deferredPathFollowsCompositionAndSpeech() throws {
    let (model, coordinator, textView, _) = try editor()
    model.head = "前半後半"
    coordinator.sync(textView)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    textView.setMarkedText("しゅうせい", selectedRange: NSRange(location: 5, length: 0), replacementRange: textView.selectedRange())
    coordinator.sync(textView)
    model.applyTentative("音声候補")
    model.requestInsertion(PaletteInsertion.insert("Sources/Example.swift", into: model.transcript.text, at: 4))
    textView.insertText("修正", replacementRange: textView.markedRange())
    coordinator.sync(textView)
    #expect(textView.string == "前半修正音声候補後半 Sources/Example.swift ")
    model.commitFinal("音声")
    #expect(textView.string == "前半修正音声後半 Sources/Example.swift ")
    #expect(model.transcript.text == textView.string)
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

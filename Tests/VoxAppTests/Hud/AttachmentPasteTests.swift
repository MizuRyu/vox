// ADR-017。貼った画像の保存・差し込み・回収のオフスクリーン検証。
// 利用者のクリップボードと実際の保存先は触らない（名前付き pasteboard と一時ディレクトリだけ）。
// 検体は合成した 8 バイトで、画像として復号できる必要はない（保存はバイト列をそのまま書く）。

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import VoxCore

@testable import VoxApp

@MainActor
@Suite("Hud: 画像のペースト")
struct AttachmentPasteTests {
  private let sample = Data("vox-png\n".utf8)

  private func pasteboard(_ name: String) -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("vox-attachment-check-\(name)"))
    board.clearContents()
    return board
  }

  private func store() -> (store: AttachmentStore, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (AttachmentStore(root: root.appendingPathComponent("attachments")), root)
  }

  /// VoxCore は AppKit を持てないので型名を文字列で持つ。値が系と一致することはここで見る。
  @Test("形式の型名は AppKit の値と一致する")
  func kindsMatchTheSystemTypes() throws {
    let expected: [AttachmentImageKind: UTType] = [
      .png: .png, .jpeg: .jpeg, .heic: .heic, .gif: .gif, .tiff: .tiff
    ]
    for kind in AttachmentImageKind.allCases {
      let type = try #require(expected[kind], "形式 \(kind.rawValue) の対応が無い")
      #expect(kind.pasteboardType == type.identifier, "\(kind.rawValue) の型名が系と違う")
    }
    for type in [NSPasteboard.PasteboardType.string, .rtf, .rtfd, .html, .fileURL] {
      #expect(
        AttachmentPaste.carriesTextOrFiles(availableTypes: [type.rawValue]),
        "\(type.rawValue) が載っているのに画像を横取りする")
    }
  }

  @Test("画像だけの pasteboard から保存する形式を決める")
  func imageOnlyPasteboardIsPicked() throws {
    let board = pasteboard("image")
    board.setData(sample, forType: .png)
    #expect(
      TranscriptImagePaste.request(from: board) == .image(sample, .png), "png を読み出せない")

    let withText = pasteboard("image-and-text")
    withText.setData(sample, forType: .png)
    withText.setString("文字", forType: .string)
    #expect(
      TranscriptImagePaste.request(from: withText) == nil,
      "テキストが同時にあるのに画像として扱った")

    let withFile = pasteboard("image-and-file")
    withFile.setData(sample, forType: .png)
    withFile.setString("file:///tmp/a.png", forType: .fileURL)
    #expect(
      TranscriptImagePaste.request(from: withFile) == nil,
      "ファイル URL が同時にあるのに画像として扱った")

    let empty = pasteboard("empty")
    #expect(TranscriptImagePaste.request(from: empty) == nil, "空の pasteboard で画像を作った")
  }

  /// 対応していない画像（PDF など）は保存せず、対応していないことだけを伝える。
  @Test("対応していない画像は保存しない")
  func unsupportedImageIsReported() throws {
    let board = pasteboard("unsupported")
    board.setData(Data("%PDF-1.4\n".utf8), forType: NSPasteboard.PasteboardType(UTType.pdf.identifier))
    #expect(TranscriptImagePaste.request(from: board) == .unsupported, "対応外の画像を見落とした")
  }

  @Test("保存できた画像は 0600 で書かれ、パスを本文に入れる")
  func savedImageBecomesAPath() throws {
    let (store, root) = store()
    defer { try? FileManager.default.removeItem(at: root) }
    guard case .saved(let path) = store.save(sample, kind: .png) else {
      Issue.record("画像を保存できなかった")
      return
    }
    #expect(path.hasSuffix(".png"), "拡張子が形式と違う: \(path)")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == sample, "書いた中身が違う")
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.intValue == 0o600, "添付が非公開で書かれていない")
    #expect(
      TranscriptImagePaste.result(
        for: .saved(path), repositoryRoot: nil, homeDirectory: NSHomeDirectory())
        == .insert(
          FilePathFormat.display(
            path: path, repositoryRoot: nil, homeDirectory: NSHomeDirectory())),
      "差し込む文字列が保存先のパスと違う")
  }

  @Test("同じ秒に 2 枚貼っても上書きしない")
  func twoImagesInTheSameSecondKeepBoth() throws {
    let (store, root) = store()
    defer { try? FileManager.default.removeItem(at: root) }
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    guard case .saved(let first) = store.save(sample, kind: .png, at: at),
      case .saved(let second) = store.save(Data("second\n".utf8), kind: .png, at: at)
    else {
      Issue.record("2 枚目を保存できなかった")
      return
    }
    #expect(first != second, "同じ名前に上書きした")
    #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == sample, "1 枚目が書き換わった")
  }

  @Test("上限を超えた画像は保存せず、保存できなかったことを伝える")
  func oversizedImageIsRefused() throws {
    let (store, root) = store()
    defer { try? FileManager.default.removeItem(at: root) }
    let oversized = Data(repeating: 0x61, count: AttachmentImageKind.maximumBytes + 1)
    #expect(store.save(oversized, kind: .png) == .failed, "上限を超えた画像を保存した")
    #expect(
      (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) == nil,
      "断った画像でフォルダを作った")
    #expect(
      TranscriptImagePaste.result(for: .failed, repositoryRoot: nil, homeDirectory: "/Users/vox")
        == .notice(TranscriptImagePaste.saveFailedNotice), "失敗の文言が違う")
  }

  @Test("回収は期限切れだけを消し、空の日付フォルダを畳む")
  func purgeRemovesExpiredFilesOnly() throws {
    let (store, root) = store()
    defer { try? FileManager.default.removeItem(at: root) }
    guard case .saved(let path) = store.save(sample, kind: .png) else {
      Issue.record("画像を保存できなかった")
      return
    }
    #expect(store.purge(now: Date()) == 0, "期限内の添付を消した")
    #expect(FileManager.default.fileExists(atPath: path), "期限内の添付が消えた")
    let later = Date().addingTimeInterval(AttachmentRetention.maximumAgeSeconds + 60)
    #expect(store.purge(now: later) == 1, "期限切れの添付を消していない")
    #expect(!FileManager.default.fileExists(atPath: path), "期限切れの添付が残っている")
    #expect(
      (try? FileManager.default.contentsOfDirectory(atPath: store.root.path))?.isEmpty == true,
      "空になった日付フォルダが残っている")
    #expect(store.purge(now: later) == 0, "消すものが無いのに数を返した")
  }

  /// 確定は書き込みを待つ（本文にパスがある ⇒ ファイルがある を保つ）。順序も貼った順。
  @Test("確定は走っている書き込みを待ち、差し込みは貼った順になる")
  func confirmWaitsForPendingWrites() async throws {
    let model = HudModel()
    // 差し込みの代わりに本文へ書いて順序を見る（本文に入るのは書き込みが終わった後だけ）。
    model.trackAttachment {
      try? await Task.sleep(for: .milliseconds(20))
      model.tail += "first "
    }
    model.trackAttachment {
      model.tail += "second"
    }
    #expect(model.tail.isEmpty, "待つ前に差し込みが終わっている")
    await model.awaitPendingAttachments()
    #expect(model.tail == "first second", "貼った順に差し込んでいない: \(model.tail)")
  }

  /// 保存の完了から本文への差し込みまでを本物のテキストビューで通す。
  /// 書き込みの間に選んだ文字は消さない（長さ 0 の位置に入れる）。
  @Test("保存が終わるとテキストビューにパスが入り、選択は消えない")
  func savedImageIsInsertedWithoutReplacingTheSelection() async throws {
    let (store, root) = store()
    defer { try? FileManager.default.removeItem(at: root) }
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = HudModel()
    let coordinator = TranscriptEditor.Coordinator(model: model)
    let scrollView = TranscriptEditor.makeScrollView(coordinator: coordinator)
    let textView = try #require(
      scrollView.documentView as? TranscriptTextView, "本文のテキストビューが組めない")
    model.head = "貼り付け先"
    model.resetToken += 1
    coordinator.sync(textView)

    textView.save(sample, kind: .png, coordinator: coordinator, store: store)
    // 書き込みの途中で「貼り付け先」を選んだまま待つ。
    textView.setSelectedRange(NSRange(location: 0, length: 5))
    await model.awaitPendingAttachments()

    let attachment = try #require(
      (try? FileManager.default.contentsOfDirectory(atPath: store.root.path))?.first,
      "添付が保存されていない")
    #expect(textView.string.contains(".png"), "本文にパスが入っていない: \(textView.string)")
    #expect(textView.string.contains("貼り付け先"), "選択していた文字が消えた: \(textView.string)")
    #expect(model.transcript.text == textView.string, "本文モデルとビューが食い違う")
    #expect(!attachment.isEmpty, "保存した日付フォルダの名前が空")
  }

  /// 2 枚以上待っている状態で HUD を出し直したら、**どの**書き込みも本文に入らない。
  @Test("HUD を出し直すと待っている書き込みは全部捨てる")
  func resetDropsEveryPendingWrite() async throws {
    let model = HudModel()
    model.trackAttachment {
      try? await Task.sleep(for: .milliseconds(30))
      model.tail += "first"
    }
    model.trackAttachment {
      model.tail += "second"
    }
    model.resetAttachments()
    await model.awaitPendingAttachments()
    #expect(model.tail.isEmpty, "取り消した書き込みが本文に入った: \(model.tail)")
  }

  @Test("画像の通知はキーヒントに戻り、HUD を出し直すと消える")
  func attachmentNoticeIsCleared() throws {
    let model = HudModel()
    model.showAttachmentNotice(TranscriptImagePaste.unsupportedNotice)
    #expect(model.attachmentNotice == TranscriptImagePaste.unsupportedNotice, "通知が出ていない")
    #expect(model.notice == nil, "本文を置き換える通知に出してしまった")
    model.resetAttachments()
    #expect(model.attachmentNotice == nil, "通知が消えていない")
  }
}

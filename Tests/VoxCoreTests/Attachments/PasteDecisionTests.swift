// ADR-017。⌘V で画像を保存するかの振り分け。本文を壊さない側を選ぶ規則を固定する。
// 型名は AppKit の rawValue をそのまま書く（一致は VoxAppTests が突き合わせる）。

import Foundation
import Testing
import VoxCore

@Suite("Attachments: ペーストの振り分け")
struct PasteDecisionTests {
  private let png = AttachmentImageKind.png.pasteboardType
  private let tiff = AttachmentImageKind.tiff.pasteboardType

  @Test("Text on the pasteboard keeps the plain paste")
  func textOnThePasteboardKeepsThePlainPaste() throws {
    for text in ["public.utf8-plain-text", "public.rtf", "com.apple.flat-rtfd", "public.html"] {
      #expect(
        AttachmentPaste.imageKind(availableTypes: [text, png]) == nil,
        "テキスト（\(text)）があるのに横取りした")
    }
  }

  @Test("Files on the pasteboard are not copied")
  func filesOnThePasteboardAreNotCopied() throws {
    #expect(
      AttachmentPaste.imageKind(availableTypes: ["public.file-url", png]) == nil,
      "ファイル URL があるのに画像として保存しようとした")
  }

  @Test("The preferred format wins when several are available")
  func thePreferredFormatWinsWhenSeveralAreAvailable() throws {
    #expect(AttachmentPaste.imageKind(availableTypes: [tiff, png]) == .png, "png を優先していない")
    #expect(AttachmentPaste.imageKind(availableTypes: [tiff]) == .tiff, "tiff だけのときに保存しない")
    #expect(
      AttachmentPaste.imageKind(availableTypes: [AttachmentImageKind.jpeg.pasteboardType, tiff])
        == .jpeg, "jpeg を tiff より優先していない")
  }

  @Test("Unsupported and empty pasteboards save nothing")
  func unsupportedAndEmptyPasteboardsSaveNothing() throws {
    #expect(AttachmentPaste.imageKind(availableTypes: []) == nil, "空の pasteboard で保存した")
    #expect(
      AttachmentPaste.imageKind(availableTypes: ["com.adobe.pdf", "public.svg-image"]) == nil,
      "対応していない形式を保存しようとした")
  }

  @Test("Only a non-empty image within the limit is accepted")
  func onlyANonEmptyImageWithinTheLimitIsAccepted() throws {
    #expect(!AttachmentImageKind.accepts(byteCount: 0), "空のデータを受けた")
    #expect(AttachmentImageKind.accepts(byteCount: 1), "1 バイトを断った")
    #expect(
      AttachmentImageKind.accepts(byteCount: AttachmentImageKind.maximumBytes),
      "上限ちょうどを断った")
    #expect(
      !AttachmentImageKind.accepts(byteCount: AttachmentImageKind.maximumBytes + 1),
      "上限を超えたデータを受けた")
  }

  /// 形式ごとに拡張子と型名が 1 つに決まっていること（名前の組み立てが形式に依存する）。
  @Test("Every format has A distinct extension and type")
  func everyFormatHasADistinctExtensionAndType() throws {
    let extensions = Set(AttachmentImageKind.allCases.map(\.fileExtension))
    let types = Set(AttachmentImageKind.allCases.map(\.pasteboardType))
    #expect(extensions.count == AttachmentImageKind.allCases.count, "拡張子が重複している")
    #expect(types.count == AttachmentImageKind.allCases.count, "型名が重複している")
  }
}

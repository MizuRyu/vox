// M3 sigil と挿入、T13 打鍵トリガーと caret 位置への挿入、finalize(through:) の位置。

import Foundation
import Testing
import VoxCore

@Suite("Palette: sigil と挿入")
struct PaletteInsertionTests {
  // MARK: M3 sigil と挿入

  @Test("Query parser takes the leading sigil")
  func queryParserTakesTheLeadingSigil() throws {
    let parsed = PaletteQueryParser.parse("#symbol", current: .file)
    #expect((parsed.sigil == .symbol) && (parsed.term == "symbol"), "先頭の sigil を食べていない: \(parsed)")
  }

  @Test("Query parser keeps the current sigil without one")
  func queryParserKeepsTheCurrentSigilWithoutOne() throws {
    let parsed = PaletteQueryParser.parse("ringbuf", current: .file)
    #expect((parsed.sigil == .file) && (parsed.term == "ringbuf"), "sigil が勝手に変わった: \(parsed)")
  }

  @Test("Only the file sigil is implemented")
  func onlyTheFileSigilIsImplemented() throws {
    let implemented = PaletteSigil.allCases.filter(\.isImplemented)
    #expect(implemented == [.file], "v1 で実装するのは @ だけのはず: \(implemented)")
  }

  @Test("Insertion surrounds the path with single spaces")
  func insertionSurroundsThePathWithSingleSpaces() throws {
    let text = PaletteInsertion.append("Sources/Vox/HudPanel.swift", to: "このファイルの")
    #expect(text == "このファイルの Sources/Vox/HudPanel.swift ", "挿入結果が違う: \"\(text)\"")
  }

  @Test("Insertion does not double an existing space")
  func insertionDoesNotDoubleAnExistingSpace() throws {
    let text = PaletteInsertion.append("a.swift", to: "このファイルの ")
    #expect(text == "このファイルの a.swift ", "空白が重なった: \"\(text)\"")
  }

  @Test("Insertion into empty text has no leading space")
  func insertionIntoEmptyTextHasNoLeadingSpace() throws {
    let text = PaletteInsertion.append("a.swift", to: "")
    #expect(text == "a.swift ", "先頭に空白が入った: \"\(text)\"")
  }

  @Test("Insertion of file name only drops the directories")
  func insertionOfFileNameOnlyDropsTheDirectories() throws {
    #expect(
      PaletteInsertion.fileName(of: "Sources/Vox/HudPanel.swift") == "HudPanel.swift"
        && PaletteInsertion.fileName(of: "README.md") == "README.md",
      "ファイル名の取り出しが違う")
  }

  // MARK: T13 `@` の打鍵トリガー

  @Test("At sign while recording opens the file palette")
  func atSignWhileRecordingOpensTheFilePalette() throws {
    expect(
      SigilTrigger.classify(replacement: "@", isRecording: true, hasOption: false), .open(.file))
  }

  @Test("Each sigil opens its own source")
  func eachSigilOpensItsOwnSource() throws {
    for sigil in PaletteSigil.allCases {
      expect(
        SigilTrigger.classify(replacement: sigil.rawValue, isRecording: true, hasOption: false),
        .open(sigil))
    }
  }

  /// `⌥@` は文字として通す（`@` を本文に入れたいときの逃げ道）。
  @Test("Option keeps the sigil as A character")
  func optionKeepsTheSigilAsACharacter() throws {
    expect(
      SigilTrigger.classify(replacement: "@", isRecording: true, hasOption: true), .insertLiteral)
  }

  /// `starting` 中は開かないし、文字としても入れない。
  @Test("Sigil while not recording is swallowed")
  func sigilWhileNotRecordingIsSwallowed() throws {
    expect(
      SigilTrigger.classify(replacement: "@", isRecording: false, hasOption: false), .ignore)
  }

  @Test("Plain character is inserted literally")
  func plainCharacterIsInsertedLiterally() throws {
    expect(
      SigilTrigger.classify(replacement: "あ", isRecording: true, hasOption: false), .insertLiteral)
  }

  @Test("Plain character outside recording is still inserted")
  func plainCharacterOutsideRecordingIsStillInserted() throws {
    expect(
      SigilTrigger.classify(replacement: "a", isRecording: false, hasOption: false), .insertLiteral)
  }

  /// 打鍵ではなく貼り付け。1 文字でないものは sigil として扱わない。
  @Test("Pasted text starting with A sigil is inserted literally")
  func pastedTextStartingWithASigilIsInsertedLiterally() throws {
    expect(
      SigilTrigger.classify(replacement: "@foo", isRecording: true, hasOption: false),
      .insertLiteral)
  }

  /// 削除（replacementString が空）は素通し。
  @Test("Empty replacement is inserted literally")
  func emptyReplacementIsInsertedLiterally() throws {
    expect(
      SigilTrigger.classify(replacement: "", isRecording: true, hasOption: false), .insertLiteral)
  }

  /// `--no-sigil-trigger`。
  @Test("Disabled trigger keeps the sigil as A character")
  func disabledTriggerKeepsTheSigilAsACharacter() throws {
    expect(
      SigilTrigger.classify(
        replacement: "@", isRecording: true, hasOption: false, enabled: false), .insertLiteral)
  }

  /// T15。変換中の `@` は変換操作の一部。パレットの合図にせず文字として通す。
  @Test("Sigil while composing is inserted literally")
  func sigilWhileComposingIsInsertedLiterally() throws {
    expect(
      SigilTrigger.classify(
        replacement: "@", isRecording: true, hasOption: false, isComposing: true), .insertLiteral)
  }

  @Test("Plain character while composing is inserted literally")
  func plainCharacterWhileComposingIsInsertedLiterally() throws {
    expect(
      SigilTrigger.classify(
        replacement: "a", isRecording: false, hasOption: false, isComposing: true), .insertLiteral)
  }

  // MARK: T13 caret 位置への挿入

  @Test("Insertion at the head has no leading space")
  func insertionAtTheHeadHasNoLeadingSpace() throws {
    let plan = PaletteInsertion.insert("a.swift", into: "この件", at: 0)
    expect(plan, text: "a.swift この件", caret: 8)
  }

  @Test("Insertion in the middle gets spaces on both sides")
  func insertionInTheMiddleGetsSpacesOnBothSides() throws {
    let plan = PaletteInsertion.insert("a.swift", into: "あいうえ", at: 2)
    expect(plan, text: "あい a.swift うえ", caret: 11)
  }

  @Test("Insertion at the end matches the append form")
  func insertionAtTheEndMatchesTheAppendForm() throws {
    let committed = "このファイルの"
    let plan = PaletteInsertion.insert(
      "Sources/Vox/HudPanel.swift", into: committed, at: (committed as NSString).length)
    #expect(plan.text == PaletteInsertion.append("Sources/Vox/HudPanel.swift", to: committed), "末尾指定が append と一致しない: \"\(plan.text)\"")
  }

  @Test("Insertion into empty text inserts only the value")
  func insertionIntoEmptyTextInsertsOnlyTheValue() throws {
    expect(
      PaletteInsertion.insert("a.swift", into: "", at: 0), text: "a.swift ", caret: 8)
  }

  @Test("Insertion does not double the surrounding spaces")
  func insertionDoesNotDoubleTheSurroundingSpaces() throws {
    expect(
      PaletteInsertion.insert("a.swift", into: "あい うえ", at: 3), text: "あい a.swift うえ",
      caret: 11)
  }

  @Test("Insertion moves the caret after the inserted text")
  func insertionMovesTheCaretAfterTheInsertedText() throws {
    let plan = PaletteInsertion.insert("a.swift", into: "あい", at: 1)
    #expect((plan.location == 1) && (plan.inserted == " a.swift ") && (plan.caret == 10), "差し込み位置か caret が違う: \(plan)")
  }

  @Test("Insertion clamps A caret beyond the end")
  func insertionClampsACaretBeyondTheEnd() throws {
    expect(
      PaletteInsertion.insert("a.swift", into: "あい", at: 99), text: "あい a.swift ", caret: 11)
  }

  @Test("Insertion of an empty value changes nothing")
  func insertionOfAnEmptyValueChangesNothing() throws {
    expect(PaletteInsertion.insert("", into: "あい", at: 1), text: "あい", caret: 1)
  }

  // MARK: M3 finalize(through:) の位置

  @Test("Finalize point stays behind the fed position")
  func finalizePointStaysBehindTheFedPosition() throws {
    // 16kHz で 1.0 秒ぶん給餌済み。マージン 100ms を引いた 0.9 秒。
    let through = AnalyzerFinalizePoint.throughSeconds(fedFrameCount: 16_000, sampleRate: 16_000)
    #expect(
      (through.map { abs($0 - 0.9) < 1e-9 }) == true,
      "through が 0.9 でない: \(String(describing: through))")
  }

  @Test("Finalize point is nil before the margin is reached")
  func finalizePointIsNilBeforeTheMarginIsReached() throws {
    // 50ms しか給餌していない。マージンに届かないので finalize を呼ばせない。
    #expect(AnalyzerFinalizePoint.throughSeconds(fedFrameCount: 800, sampleRate: 16_000) == nil, "マージン未満で through を返した")
  }

  @Test("Finalize point is nil without any fed audio")
  func finalizePointIsNilWithoutAnyFedAudio() throws {
    #expect(AnalyzerFinalizePoint.throughSeconds(fedFrameCount: 0, sampleRate: 16_000) == nil, "給餌 0 で through を返した")
  }

  @Test("Finalize point is nil without A sample rate")
  func finalizePointIsNilWithoutASampleRate() throws {
    #expect(AnalyzerFinalizePoint.throughSeconds(fedFrameCount: 16_000, sampleRate: 0) == nil, "サンプルレート 0 で through を返した")
  }

  /// この関数の目的そのもの。**まだ送っていない位置を指定しない**。
  @Test("Finalize point never exceeds the fed position for any margin")
  func finalizePointNeverExceedsTheFedPositionForAnyMargin() throws {
    for rate in [16_000.0, 44_100.0, 48_000.0] {
      for frames in stride(from: Int64(1), through: Int64(200_000), by: 4_999) {
        for margin in [-1.0, 0.0, 0.05, 0.1, 10.0] {
          guard
            let through = AnalyzerFinalizePoint.throughSeconds(
              fedFrameCount: frames, sampleRate: rate, marginSeconds: margin)
          else { continue }
          let fedSeconds = Double(frames) / rate
          #expect(
            through > 0 && through <= fedSeconds,
            "through=\(through) が給餌済み \(fedSeconds) を超えた (rate=\(rate) margin=\(margin))")
        }
      }
    }
  }
}

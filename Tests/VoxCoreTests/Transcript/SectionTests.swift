// T21 3 区画（head / tentative / tail）の状態遷移。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: head / tentative / tail")
struct SectionTests {
  // MARK: T21 3 区画（head / tentative / tail）

  /// T21。全体の末尾（淡色の後ろ）への挿入は `tail` に入る。
  @Test("Typed text at the overall tail lands in tail")
  func typedTextAtTheOverallTailLandsInTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です")
    #expect(buffer.insertTyped("X", at: 5) == true, "全体の末尾への挿入を拒否した")
    expect(buffer, head: "テスト", tentative: "です", tail: "X", caret: 6)
    #expect(buffer.text == "テストですX", "並びが違う: \(buffer.text)")
  }

  @Test("Typed text at the tail appends to the existing tail")
  func typedTextAtTheTailAppendsToTheExistingTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "X")
    #expect(buffer.insertTyped("Y", at: 6) == true, "tail 末尾への挿入を拒否した")
    expect(buffer, head: "テスト", tentative: "です", tail: "XY", caret: 7)
  }

  /// グレーの内部（`headEnd` < location < `tentativeEnd`）は拒否する。
  @Test("Typed text inside the dim tail is rejected")
  func typedTextInsideTheDimTailIsRejected() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "X")
    #expect(buffer.insertTyped("Z", at: 4) == false, "淡色域の内部への挿入を受理した")
    expect(buffer, head: "テスト", tentative: "です", tail: "X", caret: 6)
  }

  @Test("Deletion inside the dim tail is rejected")
  func deletionInsideTheDimTailIsRejected() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "X")
    #expect(buffer.replace(range: NSRange(location: 3, length: 2), with: "") == false, "淡色域の削除を受理した")
    expect(buffer, head: "テスト", tentative: "です", tail: "X", caret: 6)
  }

  /// T21。`head` から淡色域に跨る編集は拒否する。
  @Test("Edit spanning from head into the dim tail is rejected")
  func editSpanningFromHeadIntoTheDimTailIsRejected() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "XY")
    #expect(
      !buffer.canEdit(range: NSRange(location: 2, length: 2))
        && buffer.replace(range: NSRange(location: 2, length: 2), with: "") == false,
      "head から淡色域に跨る編集を受理した")
    expect(buffer, head: "テスト", tentative: "です", tail: "XY", caret: 7)
  }

  /// T21。淡色域から `tail` に跨る編集も拒否する（打った文字を音声の都合で消さない）。
  @Test("Edit spanning from the dim tail into the tail is rejected")
  func editSpanningFromTheDimTailIntoTheTailIsRejected() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "XY")
    #expect(
      !buffer.canEdit(range: NSRange(location: 4, length: 2))
        && buffer.replace(range: NSRange(location: 4, length: 2), with: "") == false,
      "淡色域から tail に跨る編集を受理した")
    expect(buffer, head: "テスト", tentative: "です", tail: "XY", caret: 7)
  }

  @Test("Deletion inside tail is accepted")
  func deletionInsideTailIsAccepted() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "あいう")
    #expect(buffer.replace(range: NSRange(location: 6, length: 1), with: "") == true, "tail 内の削除を拒否した")
    expect(buffer, head: "テスト", tentative: "です", tail: "あう", caret: 6)
  }

  /// 最重要。グレーが伸び縮みしても打った文字は消えない。
  @Test("Tentative update keeps the tail")
  func tentativeUpdateKeepsTheTail() throws {
    var buffer = TranscriptBuffer(head: "きょうは", tentative: "いい", tail: "X")
    buffer.applyTentative("いい天気")
    expect(buffer, head: "きょうは", tentative: "いい天気", tail: "X", caret: 9)
    #expect(buffer.text == "きょうはいい天気X", "並びが違う: \(buffer.text)")
  }

  /// caret が全体の末尾なら、グレーが伸びた分だけ末尾に追従する。
  @Test("Tentative update moves the caret when it is at the overall tail")
  func tentativeUpdateMovesTheCaretWhenItIsAtTheOverallTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "で")
    buffer.applyTentative("です")
    expect(buffer, head: "テスト", tentative: "です", caret: 5)
    #expect(buffer.caret == buffer.length, "末尾に追従していない: \(buffer.caret)")
  }

  /// T21 の主目的。打っている最中にグレーが更新されても、caret は同じ文字の上に残る。
  @Test("Tentative update keeps the caret inside tail")
  func tentativeUpdateKeepsTheCaretInsideTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "あい", caret: 6)
    buffer.applyTentative("で")
    expect(buffer, head: "テスト", tentative: "で", tail: "あい", caret: 5)
    #expect(buffer.text == "テストであい", "並びが違う: \(buffer.text)")
  }

  /// caret が `head` 内なら tentative 更新で動かない（`tail` があっても同じ）。
  @Test("Tentative update keeps the caret inside head with tail")
  func tentativeUpdateKeepsTheCaretInsideHeadWithTail() throws {
    var buffer = TranscriptBuffer(head: "テストです", tentative: "きょう", tail: "X", caret: 2)
    buffer.applyTentative("きょうは")
    expect(buffer, head: "テストです", tentative: "きょうは", tail: "X", caret: 2)
  }

  /// T21（T18 から反転）。final は `tail` を巻き込まない。`head` に入り、打った文字はその後ろに残る。
  @Test("Final does not merge the tail into head")
  func finalDoesNotMergeTheTailIntoHead() throws {
    var buffer = TranscriptBuffer(head: "きょうは", tentative: "いい天気", tail: "です")
    buffer.commitFinal("、")
    expect(buffer, head: "きょうは、", tentative: "", tail: "です", caret: 7)
    #expect(buffer.text == "きょうは、です", "並びが違う: \(buffer.text)")
  }

  /// 確定しても caret が全体の末尾なら末尾のまま（次に打つ位置）。
  @Test("Final at the overall tail keeps the caret at the new tail")
  func finalAtTheOverallTailKeepsTheCaretAtTheNewTail() throws {
    var buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "X")
    buffer.commitFinal("ね")
    expect(buffer, head: "テストね", tentative: "", tail: "X", caret: 5)
    #expect(buffer.caret == buffer.length, "末尾から外れた: \(buffer.caret)")
  }

  /// T21（T20 から反転）。3 区画の並びは head + tentative + tail（淡色は真ん中）。
  @Test("Buffer text is head tentative then tail")
  func bufferTextIsHeadTentativeThenTail() throws {
    let buffer = TranscriptBuffer(head: "あ", tentative: "い", tail: "う")
    #expect((buffer.text == "あいう") && (buffer.length == 3) && (buffer.headEnd == 1) && (buffer.tentativeEnd == 2), "全文か境目が違う: \(buffer.text)")
  }

  /// 既に `tail` があるときのパレット挿入も、その末尾（全体の末尾）に入る。
  @Test("Palette insertion after an existing tail goes to the end")
  func paletteInsertionAfterAnExistingTailGoesToTheEnd() throws {
    var buffer = TranscriptBuffer(head: "ここに", tentative: "しゃべり中", tail: "X")
    buffer.insertPalette("a.swift")
    expect(
      buffer, head: "ここに", tentative: "しゃべり中", tail: "X a.swift ", caret: 18)
    #expect(buffer.text == "ここにしゃべり中X a.swift ", "並びが違う: \(buffer.text)")
  }

  /// T21（T20 から反転）。淡色の内部を指した caret は全体の末尾に寄る。
  @Test("Clamp caret snaps the dim tail to the overall tail")
  func clampCaretSnapsTheDimTailToTheOverallTail() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "X")
    #expect(
      buffer.clampCaret(4) == 6
        && buffer.clampCaret(3) == 3
        && buffer.clampCaret(5) == 5
        && buffer.clampCaret(6) == 6
        && buffer.clampCaret(99) == 6
        && buffer.clampCaret(-1) == 0,
      "clamp が違う: \(buffer.clampCaret(4))")
  }

  /// 淡色域に跨る選択は、掛かっている `head` 側だけを残す。淡色の内部からの選択は末尾に寄る。
  @Test("Clamp selection crossing the dim tail keeps the head part")
  func clampSelectionCrossingTheDimTailKeepsTheHeadPart() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "X")
    let clamped = buffer.clampSelection(NSRange(location: 2, length: 3))
    #expect(clamped == NSRange(location: 2, length: 1), "選択の丸めが違う: \(clamped)")
    let fromDim = buffer.clampSelection(NSRange(location: 4, length: 1))
    #expect(fromDim == NSRange(location: 6, length: 0), "淡色内の選択が全体の末尾に寄っていない: \(fromDim)")
  }

  @Test("Clamp selection inside tail is kept")
  func clampSelectionInsideTailIsKept() throws {
    let buffer = TranscriptBuffer(head: "テスト", tentative: "です", tail: "あいう")
    let inTail = NSRange(location: 5, length: 3)
    let inHead = NSRange(location: 0, length: 3)
    #expect((buffer.clampSelection(inTail) == inTail) && (buffer.clampSelection(inHead) == inHead), "編集可能域の選択を丸めてしまった")
  }

  @Test("Init puts the caret at the overall tail by default")
  func initPutsTheCaretAtTheOverallTailByDefault() throws {
    #expect((TranscriptBuffer(head: "テスト", tentative: "です", tail: "X").caret == 6) && (TranscriptBuffer().caret == 0), "caret の既定が末尾でない")
  }

  // MARK: T21 確定は打った文字を動かさない（音声はその前に入る）

  /// 主目的（T18 から反転）。淡色が出ている間に打った文字は、確定した音声より**後ろ**に残る。
  @Test("Voice lands before the typed text on commit")
  func voiceLandsBeforeTheTypedTextOnCommit() throws {
    var buffer = TranscriptBuffer(head: "きょうは", tentative: "いい", tail: "メモ")
    buffer.commitFinal("天気")
    expect(buffer, head: "きょうは天気", tentative: "", tail: "メモ", caret: 8)
    let voice = try #require(buffer.text.range(of: "天気"))
    let typed = try #require(buffer.text.range(of: "メモ"))
    #expect(voice.upperBound <= typed.lowerBound, "音声が打った文字の前に来ていない: \(buffer.text)")
  }

  /// `head` が空（最初の一言の前に打った）でも `tail` は動かない。
  @Test("Commit without any head text keeps the tail")
  func commitWithoutAnyHeadTextKeepsTheTail() throws {
    var buffer = TranscriptBuffer(head: "", tentative: "です", tail: "打った")
    buffer.commitFinal("音声")
    expect(buffer, head: "音声", tentative: "", tail: "打った", caret: 5)
  }

  /// 淡色が無い（final だけが続いている）状態でも `tail` は動かない。
  @Test("Commit without A dim tail keeps the tail")
  func commitWithoutADimTailKeepsTheTail() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "", tail: "X")
    buffer.commitFinal("Y")
    expect(buffer, head: "あY", tentative: "", tail: "X", caret: 3)
  }

  @Test("Commit keeps the caret at the overall tail")
  func commitKeepsTheCaretAtTheOverallTail() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "い", tail: "う")
    buffer.commitFinal("え")
    #expect((buffer.caret == buffer.length) && (buffer.caret == 3), "末尾に留まっていない: \(buffer.caret) / \(buffer.length)")
  }

  /// `head` の途中を編集していた caret は確定でも動かない（そこには音声を入れない）。
  @Test("Commit leaves the caret inside head")
  func commitLeavesTheCaretInsideHead() throws {
    var buffer = TranscriptBuffer(head: "テストです", tentative: "きょう", tail: "X", caret: 2)
    buffer.commitFinal("は")
    expect(buffer, head: "テストですは", tentative: "", tail: "X", caret: 2)
  }

  /// 打った文字の中にいた caret は、同じ文字の間に残る（淡色が final に置き換わった分だけずれる）。
  @Test("Commit keeps the caret among the typed characters")
  func commitKeepsTheCaretAmongTheTypedCharacters() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "いい", tail: "うえ", caret: 4)
    buffer.commitFinal("お")
    expect(buffer, head: "あお", tentative: "", tail: "うえ", caret: 3)
  }

  /// 確定後は「head + tail」の 2 段になり、打った文字は全体の末尾に残る。
  @Test("The typed tail stays at the overall tail after A commit")
  func theTypedTailStaysAtTheOverallTailAfterACommit() throws {
    var buffer = TranscriptBuffer(head: "ここ", tentative: "しゃべり中", tail: "打った")
    buffer.commitFinal("です")
    #expect((buffer.text == buffer.head + buffer.tail) && (buffer.tail == "打った") && (buffer.tentativeEnd == buffer.headEnd), "打った文字が末尾に残っていない: \(buffer.text)")
  }

  /// 最重要。打鍵と final を交互に繰り返しても、打った文字は 1 文字も失われない。
  @Test("No typed character is lost across repeated commits")
  func noTypedCharacterIsLostAcrossRepeatedCommits() throws {
    var buffer = TranscriptBuffer(head: "", tentative: "しゃべり中")
    #expect(buffer.insertTyped("あ", at: buffer.length) == true, "1 回目の打鍵を拒否した")
    buffer.commitFinal("A")
    buffer.applyTentative("つづき")
    #expect(buffer.insertTyped("い", at: buffer.length) == true, "2 回目の打鍵を拒否した")
    buffer.commitFinal("B")
    expect(buffer, head: "AあB", tentative: "", tail: "い", caret: 4)
    #expect(buffer.text == "AあBい", "並びが違う: \(buffer.text)")
  }

  /// 確定した後のパレット挿入も全体の末尾に入る（淡色が無いので `head` に入る）。
  @Test("Palette insertion after A commit lands at the overall tail")
  func paletteInsertionAfterACommitLandsAtTheOverallTail() throws {
    var buffer = TranscriptBuffer(head: "ここに", tentative: "しゃべり中", tail: "メモ")
    buffer.commitFinal("と")
    buffer.insertPalette("a.swift")
    expect(
      buffer, head: "ここにとメモ a.swift ", tentative: "", tail: "", caret: 15)
    #expect(buffer.text == "ここにとメモ a.swift ", "並びが違う: \(buffer.text)")
  }

  // MARK: T21 淡色は 3 区画の真ん中（打った文字はその後ろ）

  /// 主目的（T20 から反転）。打った文字は淡色の**後ろ**に入る。
  @Test("The typed text sits behind the dim tail while typing")
  func theTypedTextSitsBehindTheDimTailWhileTyping() throws {
    var buffer = TranscriptBuffer(head: "きょうは", tentative: "いい天気")
    #expect(buffer.insertTyped("メモ", at: buffer.length) == true, "淡色の後ろへの打鍵を拒否した")
    #expect((buffer.text == "きょうはいい天気メモ") && (buffer.text.hasSuffix(buffer.tail)) && (buffer.tentativeEnd == 8), "打った文字が淡色の後ろに無い: \(buffer.text)")
  }

  /// 打っている最中に淡色が更新されても、打った文字は淡色の後ろに残り caret も同じ文字の上にいる。
  @Test("Tentative update does not move the typed characters")
  func tentativeUpdateDoesNotMoveTheTypedCharacters() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "い", tail: "メモ", caret: 3)
    buffer.applyTentative("いいいいい")
    buffer.applyTentative("")
    #expect(
      buffer.head == "あ" && buffer.tail == "メモ" && buffer.text == "あメモ" && buffer.caret == 2,
      "打った文字が動いた: text=\(buffer.text) caret=\(buffer.caret)")
  }

  /// 淡色が伸びても打った文字は押し出されない（末尾に残る）。
  @Test("Tentative update does not push the typed characters around")
  func tentativeUpdateDoesNotPushTheTypedCharactersAround() throws {
    var buffer = TranscriptBuffer(head: "確定", tentative: "しゃ", tail: "打った")
    buffer.applyTentative("しゃべっている途中")
    #expect((buffer.text.hasSuffix("打った")) && (buffer.text == "確定しゃべっている途中打った"), "打った文字が押し出された: \(buffer.text)")
  }

  /// T21（T20 から反転）。淡色の内部を指した caret は全体の末尾に寄る（次に打つ自然な位置）。
  @Test("Clamp caret inside the dim tail snaps to the overall tail")
  func clampCaretInsideTheDimTailSnapsToTheOverallTail() throws {
    let buffer = TranscriptBuffer(head: "あい", tentative: "うえお", tail: "X")
    #expect((buffer.clampCaret(3) == 6) && (buffer.clampCaret(4) == 6), "全体の末尾に寄っていない: \(buffer.clampCaret(3))")
  }

  /// 淡色の直前（`headEnd`）と直後（`tentativeEnd`）と全体の末尾は、どれもそのまま置ける。
  @Test("Clamp caret at the edges of the dim tail is kept")
  func clampCaretAtTheEdgesOfTheDimTailIsKept() throws {
    var buffer = TranscriptBuffer(head: "あい", tentative: "うえお", tail: "X")
    buffer.setCaret(buffer.headEnd)
    #expect(buffer.caret == 2, "淡色の直前に置けない: \(buffer.caret)")
    buffer.setCaret(buffer.tentativeEnd)
    #expect(buffer.caret == 5, "淡色の直後に置けない: \(buffer.caret)")
    buffer.setCaret(buffer.length)
    #expect(buffer.caret == 6, "全体の末尾に置けない: \(buffer.caret)")
  }

  /// T21（T20 から反転）。淡色の直前への挿入は `head` に入る（`tail` には足さない）。
  @Test("Insertion just before the dim tail goes to head")
  func insertionJustBeforeTheDimTailGoesToHead() throws {
    var buffer = TranscriptBuffer(head: "あい", tentative: "うえ")
    #expect(buffer.insertTyped("X", at: buffer.headEnd) == true, "淡色の直前への挿入を拒否した")
    expect(buffer, head: "あいX", tentative: "うえ", tail: "", caret: 3)
  }

  /// 淡色の直後（`tail` の先頭）への挿入は `tail` の先頭に入る。
  @Test("Insertion just after the dim tail goes to the tail head")
  func insertionJustAfterTheDimTailGoesToTheTailHead() throws {
    var buffer = TranscriptBuffer(head: "あい", tentative: "うえ", tail: "X")
    #expect(buffer.insertTyped("Y", at: buffer.tentativeEnd) == true, "淡色の直後への挿入を拒否した")
    expect(buffer, head: "あい", tentative: "うえ", tail: "YX", caret: 5)
  }

  /// 全体の末尾への挿入は `tail` の末尾に入る。
  @Test("Insertion at the overall tail is still allowed")
  func insertionAtTheOverallTailIsStillAllowed() throws {
    var buffer = TranscriptBuffer(head: "あい", tentative: "うえ", tail: "X")
    #expect((buffer.canEdit(range: NSRange(location: buffer.length, length: 0))) && (buffer.insertTyped("Y", at: buffer.length) == true), "全体の末尾への挿入を拒否した")
    expect(buffer, head: "あい", tentative: "うえ", tail: "XY", caret: 6)
  }

  /// T21（T20 から反転）。確定の規則は `head += final` だけ。`tail` は動かさない。
  @Test("Commit final leaves the tail where it is")
  func commitFinalLeavesTheTailWhereItIs() throws {
    var buffer = TranscriptBuffer(head: "きょうは", tentative: "いい", tail: "メモ")
    buffer.commitFinal("天気")
    expect(buffer, head: "きょうは天気", tentative: "", tail: "メモ", caret: 8)
    #expect(buffer.text == "きょうは天気メモ", "並びが違う: \(buffer.text)")
  }

  // MARK: T21 時間順の 3 区画（指示書の「期待される振る舞い」）

  /// 指示書の 6 ステップをそのまま辿る。各段で全文・caret・3 区画を検査する。
  /// **打った文字（ccc）はどの段でも動かない。**
  @Test("The six step timeline keeps the typed text still")
  func theSixStepTimelineKeepsTheTypedTextStill() throws {
    // 1. 喋る「あいう」→ 確定。head="あいう" 表示: あいう
    var buffer = TranscriptBuffer()
    buffer.commitFinal("あいう")
    expect(buffer, head: "あいう", tentative: "", tail: "", caret: 3)
    #expect(buffer.text == "あいう", "1: \(buffer.text)")

    // 2. 喋る「えお…」（淡色）。head="あいう" 淡色="えお" 表示: あいう[えお]
    buffer.applyTentative("えお")
    expect(buffer, head: "あいう", tentative: "えお", tail: "", caret: 5)
    #expect(buffer.text == "あいうえお", "2: \(buffer.text)")

    // 3. "ccc" と打つ。tail="ccc" 表示: あいう[えお]ccc ← 淡色の後ろに入る
    #expect(buffer.insertTyped("ccc", at: buffer.caret) == true, "3: 打鍵を拒否した")
    expect(buffer, head: "あいう", tentative: "えお", tail: "ccc", caret: 8)
    #expect(buffer.text == "あいうえおccc", "3: \(buffer.text)")

    // 4. 淡色が「えおか」に更新。淡色="えおか" 表示: あいう[えおか]ccc ← ccc は動かない
    buffer.applyTentative("えおか")
    expect(buffer, head: "あいう", tentative: "えおか", tail: "ccc", caret: 9)
    #expect(buffer.text == "あいうえおかccc", "4: \(buffer.text)")

    // 5. 確定。head="あいうえおか" tail="ccc" 表示: あいうえおかccc ← ccc は動かない
    buffer.commitFinal("えおか")
    expect(buffer, head: "あいうえおか", tentative: "", tail: "ccc", caret: 9)
    #expect(buffer.text == "あいうえおかccc", "5: \(buffer.text)")

    // 6. 喋る「きく…」（新しい淡色）。head="あいうえおかccc" 淡色="きく"
    //    表示: あいうえおかccc[きく] ← ccc が確定に合流
    buffer.applyTentative("きく")
    expect(buffer, head: "あいうえおかccc", tentative: "きく", tail: "", caret: 11)
    #expect(buffer.text == "あいうえおかcccきく", "6: \(buffer.text)")
  }

  /// 淡色が空 → 非空になるとき、`tail` は `head` に合流する（打鍵はその後の音声より前）。
  @Test("Tail merges into head when A new dim tail starts")
  func tailMergesIntoHeadWhenANewDimTailStarts() throws {
    var buffer = TranscriptBuffer(head: "確定", tentative: "", tail: "打った")
    buffer.applyTentative("しゃべり中")
    expect(buffer, head: "確定打った", tentative: "しゃべり中", tail: "", caret: 10)
    #expect(buffer.text == "確定打ったしゃべり中", "並びが違う: \(buffer.text)")
  }

  /// 合流は「空 → 非空」の 1 回だけ。淡色の更新では合流しない（`tail` は淡色の後ろに残る）。
  @Test("Tail merges only when the dim tail was empty")
  func tailMergesOnlyWhenTheDimTailWasEmpty() throws {
    var buffer = TranscriptBuffer(head: "確定", tentative: "しゃ", tail: "打った")
    buffer.applyTentative("しゃべり")
    expect(buffer, head: "確定", tentative: "しゃべり", tail: "打った", caret: 9)
    buffer.applyTentative("しゃべります")
    expect(buffer, head: "確定", tentative: "しゃべります", tail: "打った", caret: 11)
  }

  /// 合流の直後に始まる淡色は、合流した打鍵の**後ろ**に出る（時間順）。
  @Test("The new dim tail starts behind the merged typed text")
  func theNewDimTailStartsBehindTheMergedTypedText() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "", tail: "XY")
    buffer.applyTentative("うえ")
    #expect((buffer.text == "あXYうえ") && (buffer.headEnd == 3) && (buffer.tail.isEmpty), "合流後の並びが違う: \(buffer.text) headEnd=\(buffer.headEnd)")
  }

  /// 淡色が空のまま打った文字は `head` に入る（`tail` は淡色が出ている間だけの区画）。
  @Test("Typed text without A dim tail lands in head")
  func typedTextWithoutADimTailLandsInHead() throws {
    var buffer = TranscriptBuffer(head: "あい", tentative: "")
    #expect(buffer.insertTyped("X", at: buffer.length) == true, "末尾への打鍵を拒否した")
    expect(buffer, head: "あいX", tentative: "", tail: "", caret: 3)
  }

  /// 淡色が無いときは `head` と `tail` が地続き。跨る削除も受理して 1 本に繋ぐ。
  @Test("Deletion spanning head and tail without A dim tail is accepted")
  func deletionSpanningHeadAndTailWithoutADimTailIsAccepted() throws {
    var buffer = TranscriptBuffer(head: "あい", tentative: "", tail: "うえ")
    #expect(buffer.replace(range: NSRange(location: 1, length: 2), with: "") == true, "淡色が無いのに跨る削除を拒否した")
    expect(buffer, head: "あえ", tentative: "", tail: "", caret: 1)
  }

  /// 淡色の更新でも確定でも、`tail` の文字列そのものは一度も変わらない。
  @Test("The tail string never changes across voice transitions")
  func theTailStringNeverChangesAcrossVoiceTransitions() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "い")
    #expect(buffer.insertTyped("メモ", at: buffer.length) == true, "打鍵を拒否した")
    for update in ["いい", "いいい", "い", ""] {
      buffer.applyTentative(update)
      #expect(buffer.tail == "メモ", "淡色の更新で tail が変わった: \(buffer.tail)")
    }
    buffer.commitFinal("うえお")
    #expect((buffer.tail == "メモ") && (buffer.text.hasSuffix("メモ")), "確定で tail が変わった: \(buffer.text)")
  }

  /// 打った文字の全体オフセットは、確定では動かない（淡色と final の長さが同じとき）。
  @Test("Commit does not shift the typed text when the final matches the dim tail")
  func commitDoesNotShiftTheTypedTextWhenTheFinalMatchesTheDimTail() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "いう", tail: "XY")
    let before = buffer.tentativeEnd
    buffer.commitFinal("いう")
    #expect((buffer.tentativeEnd == before) && (buffer.text == "あいうXY"), "打った文字がずれた: \(buffer.text)")
  }

  /// 打鍵 → 確定 → 打鍵 → 確定 を繰り返しても、打った文字の並びは崩れない。
  @Test("Typed characters keep their order across many cycles")
  func typedCharactersKeepTheirOrderAcrossManyCycles() throws {
    var buffer = TranscriptBuffer()
    for (index, voice) in ["ひとつ", "ふたつ", "みっつ"].enumerated() {
      buffer.applyTentative(voice)
      #expect(buffer.insertTyped("\(index)", at: buffer.length) == true, "\(index) 回目の打鍵を拒否した")
      buffer.commitFinal(voice)
    }
    #expect(buffer.text == "ひとつ0ふたつ1みっつ2", "並びが違う: \(buffer.text)")
    #expect(buffer.tail == "2", "最後の打鍵が tail に残っていない: \(buffer.tail)")
  }

  /// 打っている最中の淡色の更新と確定を通して、caret は打った文字の同じ位置に留まる。
  @Test("The caret stays between the same typed characters")
  func theCaretStaysBetweenTheSameTypedCharacters() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "いい")
    #expect(buffer.insertTyped("XY", at: buffer.length) == true, "打鍵を拒否した")
    buffer.setCaret(buffer.length - 1)
    buffer.applyTentative("いいいい")
    buffer.commitFinal("うう")
    let text = buffer.text as NSString
    #expect(
      text.substring(with: NSRange(location: buffer.caret - 1, length: 2)) == "XY"
        && buffer.caret == buffer.length - 1,
      "caret が打った文字から外れた: \(buffer.caret) / \(buffer.text)")
  }

  /// 打った文字は淡色の内部として扱われない（`tail` は編集可能域）。
  @Test("The tail stays editable while the dim tail is showing")
  func theTailStaysEditableWhileTheDimTailIsShowing() throws {
    let buffer = TranscriptBuffer(head: "あい", tentative: "うえ", tail: "XY")
    #expect(
      buffer.canEdit(range: NSRange(location: 4, length: 2))
        && buffer.canEdit(range: NSRange(location: 5, length: 1))
        && buffer.canEdit(range: NSRange(location: 6, length: 0)),
      "tail の編集を拒否した")
  }

  /// パレット挿入は淡色が出ていても全体の末尾（`tail` の末尾）に入る。
  @Test("Palette insertion goes behind the dim tail")
  func paletteInsertionGoesBehindTheDimTail() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "いう", tail: "X")
    buffer.insertPalette("a.swift")
    #expect((buffer.text == "あいうX a.swift ") && (buffer.tail == "X a.swift "), "パレットが末尾に入っていない: \(buffer.text)")
  }

  /// 合流したあとに打った文字も、次の確定で動かない（合流は 1 回きりで積み上がらない）。
  @Test("Typed text after A merge still does not move on the next commit")
  func typedTextAfterAMergeStillDoesNotMoveOnTheNextCommit() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "", tail: "X")
    buffer.applyTentative("いい")
    #expect(buffer.insertTyped("Y", at: buffer.length) == true, "合流後の打鍵を拒否した")
    expect(buffer, head: "あX", tentative: "いい", tail: "Y", caret: 5)
    buffer.commitFinal("いい")
    expect(buffer, head: "あXいい", tentative: "", tail: "Y", caret: 5)
    #expect(buffer.text == "あXいいY", "並びが違う: \(buffer.text)")
  }

  /// 確定で淡色が空になった後の打鍵は `head` に入り、次の淡色はその後ろに出る。
  @Test("Typing after A commit lands in head and the next dim tail follows it")
  func typingAfterACommitLandsInHeadAndTheNextDimTailFollowsIt() throws {
    var buffer = TranscriptBuffer(head: "あ", tentative: "いい", tail: "X")
    buffer.commitFinal("いい")
    #expect(buffer.insertTyped("Z", at: buffer.length) == true, "確定後の打鍵を拒否した")
    expect(buffer, head: "あいいXZ", tentative: "", tail: "", caret: 5)
    buffer.applyTentative("うう")
    expect(buffer, head: "あいいXZ", tentative: "うう", tail: "", caret: 7)
  }
}

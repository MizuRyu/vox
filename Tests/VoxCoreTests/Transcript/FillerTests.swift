// FillerPass の規則テスト。ADR-012 の表の各行につき 2 ケース以上 +
// 「除去しない語」3 つ + 「畳み」2 つ。入力は Apple SpeechTranscriber の出力に似せる
// （句読点は「、」「。」、空白は半角）。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: フィラー除去")
struct FillerTests {
  // MARK: 単独フィラー（左が読点・句点・空白・文頭。あの / その / まあ は両側を要求する）

  @Test("Solo filler at sentence start is removed")
  func soloFillerAtSentenceStartIsRemoved() throws {
    expect(FillerPass.remove(from: "えっと、テストです"), "テストです", 1)
  }

  @Test("Solo filler between commas is removed")
  func soloFillerBetweenCommasIsRemoved() throws {
    expect(FillerPass.remove(from: "今日は、あの、天気がいい"), "今日は、天気がいい", 1)
  }

  @Test("Solo filler separated by space is removed")
  func soloFillerSeparatedBySpaceIsRemoved() throws {
    expect(FillerPass.remove(from: "えっと テストです"), "テストです", 1)
  }

  /// 文末に接する場合も除去する。残った読点はそのまま（文頭の読点だけ落とす規則）。
  @Test("Solo filler at end of text is removed")
  func soloFillerAtEndOfTextIsRemoved() throws {
    expect(FillerPass.remove(from: "テストです、えっと"), "テストです、", 1)
  }

  @Test("Every solo filler in the table is removed")
  func everySoloFillerInTheTableIsRemoved() throws {
    expect(
      FillerPass.remove(from: "えっと、えー、えーと、あの、あのー、その、うーん、んー、まあ、テスト"),
      "テスト", 9)
  }

  /// M2 の実測で観測した実際の出力。Apple はフィラーの後に読点を打たないことがある。
  /// 「えっと」は後続の語の一部になりえないので、左が句点なら消す。
  @Test("Solo filler without trailing boundary is removed")
  func soloFillerWithoutTrailingBoundaryIsRemoved() throws {
    expect(FillerPass.remove(from: "消したいっす。えっとデータ層。"), "消したいっす。データ層。", 1)
  }

  /// 「あのファイル」の「あの」は連体詞。左が文頭でも右が語なら消してはいけない。
  @Test("Solo filler attached to A word is kept")
  func soloFillerAttachedToAWordIsKept() throws {
    expect(FillerPass.remove(from: "あのファイルを開いて"), "あのファイルを開いて", 0)
  }

  @Test("Demonstrative filler attached to A word is kept")
  func demonstrativeFillerAttachedToAWordIsKept() throws {
    expect(FillerPass.remove(from: "そのファイルを保存して"), "そのファイルを保存して", 0)
  }

  // MARK: 相槌（文頭または読点に挟まれた場合のみ）

  @Test("Aizuchi at sentence start is removed")
  func aizuchiAtSentenceStartIsRemoved() throws {
    expect(FillerPass.remove(from: "はい、わかりました"), "わかりました", 1)
  }

  @Test("Aizuchi between commas is removed")
  func aizuchiBetweenCommasIsRemoved() throws {
    expect(FillerPass.remove(from: "それで、うん、進めます"), "それで、進めます", 1)
  }

  @Test("Aizuchi inside A word is kept")
  func aizuchiInsideAWordIsKept() throws {
    expect(FillerPass.remove(from: "うんざりする話です"), "うんざりする話です", 0)
  }

  @Test("Aizuchi without trailing boundary is kept")
  func aizuchiWithoutTrailingBoundaryIsKept() throws {
    expect(FillerPass.remove(from: "返事は、はいです"), "返事は、はいです", 0)
  }

  // MARK: 感動詞（文頭で直後に読点がある場合のみ）

  @Test("Interjection at sentence start is removed")
  func interjectionAtSentenceStartIsRemoved() throws {
    expect(FillerPass.remove(from: "あ、そうそう、明日ですね"), "明日ですね", 2)
  }

  @Test("Interjection with long vowel is removed")
  func interjectionWithLongVowelIsRemoved() throws {
    expect(FillerPass.remove(from: "あー、なるほど"), "なるほど", 1)
  }

  @Test("Interjection after period is removed")
  func interjectionAfterPeriodIsRemoved() throws {
    expect(FillerPass.remove(from: "終わりです。あ、そうだ"), "終わりです。そうだ", 1)
  }

  /// ADR-012 の例「あ、そうそう、」→ 空は規則としては当たる（removedCount 2）。
  /// B-6 以降、全部が除去対象だった発話は挿入するものが無くならないよう原文を返す。
  @Test("Interjection only utterance keeps its text")
  func interjectionOnlyUtteranceKeepsItsText() throws {
    expect(FillerPass.remove(from: "あ、そうそう、"), "あ、そうそう、", 2)
  }

  @Test("Interjection without following comma is kept")
  func interjectionWithoutFollowingCommaIsKept() throws {
    expect(FillerPass.remove(from: "あそこに置いて"), "あそこに置いて", 0)
  }

  // MARK: 除去しない語（ADR-012「誤除去のコストが高い」）

  @Test("Nanka is kept")
  func nankaIsKept() throws {
    expect(FillerPass.remove(from: "なんか、それは違う"), "なんか、それは違う", 0)
  }

  @Test("Nandakke is kept")
  func nandakkeIsKept() throws {
    expect(FillerPass.remove(from: "えっと、なんだっけ、あれです"), "なんだっけ、あれです", 1)
  }

  @Test("Janakute is kept")
  func janakuteIsKept() throws {
    expect(FillerPass.remove(from: "これ、じゃなくて、あれ"), "これ、じゃなくて、あれ", 0)
  }

  // MARK: 畳み

  @Test("Consecutive commas are folded into one")
  func consecutiveCommasAreFoldedIntoOne() throws {
    expect(FillerPass.remove(from: "これは、えっと、あの、テストです"), "これは、テストです", 2)
  }

  @Test("Period wins over comma when folded")
  func periodWinsOverCommaWhenFolded() throws {
    expect(FillerPass.remove(from: "始めます。はい、次です"), "始めます。次です", 1)
  }

  @Test("Consecutive spaces are folded into one")
  func consecutiveSpacesAreFoldedIntoOne() throws {
    expect(FillerPass.remove(from: "テスト  です"), "テスト です", 0)
  }

  // MARK: その他

  @Test("Empty text is unchanged")
  func emptyTextIsUnchanged() throws {
    expect(FillerPass.remove(from: ""), "", 0)
  }

  @Test("Text without filler is unchanged")
  func textWithoutFillerIsUnchanged() throws {
    expect(
      FillerPass.remove(from: "ファイルを開いて保存してください。"), "ファイルを開いて保存してください。", 0)
  }

  @Test("Multiple sentences keep their periods")
  func multipleSentencesKeepTheirPeriods() throws {
    expect(
      FillerPass.remove(from: "えっと、開きます。あの、保存します。"), "開きます。保存します。", 2)
  }

  // MARK: 全文がフィラーの発話（B-6。空にすると確定が `empty_text` で失敗する）

  @Test("A backchannel only utterance keeps its text")
  func backchannelOnlyUtteranceKeepsItsText() throws {
    expect(FillerPass.remove(from: "はい"), "はい", 1)
  }

  @Test("Repeated backchannels keep their text")
  func repeatedBackchannelsKeepTheirText() throws {
    expect(FillerPass.remove(from: "はい はい"), "はい はい", 2)
  }

  @Test("An utterance of only fillers keeps its text")
  func fillerOnlyUtteranceKeepsItsText() throws {
    expect(FillerPass.remove(from: "えっと、あの、うーん"), "えっと、あの、うーん", 3)
  }

  // MARK: フラグ `--no-filler-removal`（R18）

  @Test("Disabled flag keeps fillers and counts zero")
  func disabledFlagKeepsFillersAndCountsZero() throws {
    let result = FillerPass.remove(from: "えっと、あの、テストです", enabled: false)
    expect(result, "えっと、あの、テストです", 0)
  }

  @Test("Enabled flag matches the plain entry point")
  func enabledFlagMatchesThePlainEntryPoint() throws {
    let text = "あ、そうそう、明日ですね"
    let gated = FillerPass.remove(from: text, enabled: true)
    let plain = FillerPass.remove(from: text)
    #expect(gated == plain, "enabled:true が既定と一致しない")
  }
}

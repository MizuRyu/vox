// ADR-028。文字だけで疑問と言える文末だけ「？」にし、「かな」「の」などの曖昧な文末は変えない。
// 入力は Apple SpeechTranscriber の出力に似せた合成文。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: 疑問符")
struct QuestionMarkTests {
  @Test("Haasの文末だけ記号を補い、疑問・途中の節・既存の約物を区別する",
    arguments: [
      ("これでいいですか", "これでいいですか？"),
      ("えっと、これでいいですかね", "これでいいですかね？"),
      ("台帳を更新します", "台帳を更新します。"),
      ("その台帳を", "その台帳を"),
      ("反映したいけど", "反映したいけど"),
      ("台帳を更新します。", "台帳を更新します。"),
      ("できますか？", "できますか？"),
      ("できますか?あの、ちなみに確認します。", "できますか?ちなみに、確認します。"),
      ("完了です!えっと。次に進みます。", "完了です!次に進みます。"),
      ("メモ.txt", "メモ.txt"),
      ("API", "API"),
      ("えっと。", ""),
      ("ちなみにこれでいいですか", "ちなみに、これでいいですか？"),
      ("確認します次に反映します", "確認します。次に反映します。"),
      ("例えば台帳を開きます", "例えば、台帳を開きます。"),
      ("例えば、台帳を開きます。", "例えば、台帳を開きます。"),
      ("まずいです", "まずいです。"),
      ("例えばという語を残してください", "例えばという語を残してください。")
    ])
  func missingSentenceMarks(input: String, expected: String) {
    let result = CommittedText.clean(input, dictionary: DictionaryTable(contents: ""),
      fillerRemovalEnabled: true, completingSentence: true)
    #expect(result.text == expected)
  }

  @Test("フィラー除去の設定にかかわらずモデルの文末記号を重複させない",
    arguments: [true, false])
  func existingSentenceMarks(fillerRemovalEnabled: Bool) {
    let result = CommittedText.clean(
      "えーあいですか。。次も確認しますか?。完了です。！？。", dictionary: DictionaryTable(contents: "えーあい\tAI"),
      fillerRemovalEnabled: fillerRemovalEnabled, completingSentence: true)
    #expect(result.text == "AIですか？次も確認しますか?完了です！？")
  }

  @Test("引用・コード・URL 内の記号は正規化せず、通常文の重複疑問符・感嘆符も保つ",
    arguments: [true, false])
  func quotesCodeAndRepeatedMarksArePreserved(fillerRemovalEnabled: Bool) {
    let quoted = CommittedText.clean(
      "「値?。」と`let x = \"。。\"`と``値?。``を確認します。", dictionary: DictionaryTable(contents: ""),
      fillerRemovalEnabled: fillerRemovalEnabled, completingSentence: true)
    #expect(quoted.text == "「値?。」と`let x = \"。。\"`と``値?。``を確認します。")

    let url = CommittedText.clean(
      "https://example.test/資料。?q=1 https://example.test/資料。。?q=1 https://example.test/確認できますか。?q=1 https://example.test/です次に",
      dictionary: DictionaryTable(contents: ""),
      fillerRemovalEnabled: fillerRemovalEnabled, completingSentence: true)
    #expect(
      url.text
        == "https://example.test/資料。?q=1 https://example.test/資料。。?q=1 https://example.test/確認できますか。?q=1 https://example.test/です次に")

    let multiBacktick = CommittedText.clean(
      "``値。。``と``値?うーん=1``を確認します。", dictionary: DictionaryTable(contents: ""),
      fillerRemovalEnabled: fillerRemovalEnabled, completingSentence: true)
    #expect(multiBacktick.text == "``値。。``と``値?うーん=1``を確認します。")

    let repeated = CommittedText.clean(
      "本当??。すごい!!。", dictionary: DictionaryTable(contents: ""),
      fillerRemovalEnabled: fillerRemovalEnabled, completingSentence: true)
    #expect(repeated.text == "本当??すごい!!")
  }

  @Test("12秒の上限とパレットで切っただけの区間に句点を補わない")
  func incompleteBoundary() {
    let text = "台帳を更新します"
    #expect(CommittedText.clean(text, dictionary: DictionaryTable(contents: ""), fillerRemovalEnabled: true).text == text)
  }

  @Test(
    "Polite questions and recall endings get a question mark",
    arguments: [
      ("これで合っていますか。", "これで合っていますか？"),
      ("どうでしたか。", "どうでしたか？"),
      ("もう終わりましたか。", "もう終わりましたか？"),
      ("一緒にやりませんか。", "一緒にやりませんか？"),
      ("それで良いでしょうか。", "それで良いでしょうか？"),
      ("それって本当ですかね。", "それって本当ですかね？"),
      ("あれ何だっけ。", "あれ何だっけ？"),
      ("お願いしてもいいっすか。", "お願いしてもいいっすか？"),
      ("他にやることないすかね。", "他にやることないすかね？"),
      ("リンクにすればよくね。", "リンクにすればよくね？"),
      ("人間読めなくね。", "人間読めなくね？"),
      ("見てもらう方が良くない。", "見てもらう方が良くない？"),
      ("ちょっと探してくれん。", "ちょっと探してくれん？"),
      ("いつでしたっけ 。", "いつでしたっけ？")
    ])
  func questionEndingsGetQuestionMark(input: String, expected: String) {
    #expect(QuestionMarkPass.apply(to: input) == expected)
  }

  @Test(
    "Endings that can be a monologue or a statement are left alone",
    arguments: [
      "今日は早めに帰ろうかな。",
      "そうなのか。",
      "これでいいの。",
      "やってみようじゃないか。",
      "確認しますか、それとも後にしますか",
      "それでいいです。",
      "これは良くない。",
      "まだ寝てなくてね。",
      "誰も来てくれんかった。"
    ])
  func ambiguousEndingsAreUnchanged(input: String) {
    #expect(QuestionMarkPass.apply(to: input) == input)
  }

  @Test("Every sentence in a segment is checked on its own")
  func eachSentenceIsChecked() {
    #expect(
      QuestionMarkPass.apply(to: "これで合っていますか。次に進もうかな。いつでしたっけ。")
        == "これで合っていますか？次に進もうかな。いつでしたっけ？")
  }

  @Test("The committed text pipeline adds the mark after filler removal")
  func pipelineAddsMarkAfterFillers() {
    let cleaned = CommittedText.clean(
      "えっと、これで合っていますか。", dictionary: DictionaryTable(contents: ""),
      fillerRemovalEnabled: true)
    #expect(cleaned.text.hasSuffix("合っていますか？"), "\(cleaned.text)")
  }
}

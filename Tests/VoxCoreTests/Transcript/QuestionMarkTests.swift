// ADR-028。文字だけで疑問と言える文末だけ「？」にし、「かな」「の」などの曖昧な文末は変えない。
// 入力は Apple SpeechTranscriber の出力に似せた合成文。

import Foundation
import Testing
import VoxCore

@Suite("Transcript: 疑問符")
struct QuestionMarkTests {
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

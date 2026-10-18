// 疑問の文末の「。」を「？」にする（ADR-028）。文字だけで疑問と言える形に限る。
// why: 「かな」「の」「のか」は独り言・平叙にもなる。語尾の上げ下げを見ずに変えると誤りが増える。

import Foundation

public enum QuestionMarkPass {
  /// 丁寧語の疑問（「ですか」「ませんか」「でしょうかね」）と、思い出しの「っけ」。
  public static func apply(to text: String) -> String {
    text.replacing(#/((?:です|ます|でした|ました|ません|でしょう)か(?:ね)?|っけ)[ 　]*。/#) {
      "\($0.output.1)？"
    }
  }
}

import Foundation

/// 発話が区切れた確定文だけを補う。途中の節や既存の約物は変えない。
public enum SentencePunctuationPass {
  public static func apply(to text: String) -> String {
    var result = text.replacingOccurrences(
      of: #"(です|ます|でした|ました|ください)(?=ちなみに|例えば|たとえば|ただし|一方で|次に)"#,
      with: "$1。", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"(^|[。！？?!])(ちなみに|例えば|たとえば|ただし|一方で|まず(?!い))(?!(?:という|と書))(?=[\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9])"#,
      with: "$1$2、", options: .regularExpression)
    // 区切りだけで句点を打たず、言い切りと分かる語尾に限る。
    return result.replacingOccurrences(
      of: #"(です(?:ね|よ|よね)?|ます(?:ね|よ|よね)?|でした|ました|ません(?:でした)?|ください(?:ね)?|思う|したい|したかった|っす(?:ね)?|だよ|だね|なんです|大丈夫|了解|なるほど)[ 　]*$"#,
      with: "$1。", options: .regularExpression)
  }
}

import Foundation

/// 確定差分を「HUD に出して貼り付ける形」に直す。本体（App.swift の clean）と検査が
/// 同じ順序を通るように、順序はここだけに置く。
public enum CommittedText {
  private static let quotePairs: [Character: Character] = ["「": "」", "『": "』", "`": "`", "\"": "\""]

  /// why: 辞書 → フィラー除去の順（ADR-019 → ADR-012）。逆順にすると、フィラーと同じ音で
  /// 始まる誤認識（「えーあい」）の頭が先に削られ、利用者が履歴の raw_text で見た左辺が残らない。
  /// 疑問符（ADR-028）はフィラー除去後の文末を見る。
  public static func clean(
    _ delta: String, dictionary: DictionaryTable, fillerRemovalEnabled: Bool, completingSentence: Bool = false
  ) -> FillerRemoval {
    let removal = FillerPass.remove(
      from: DictionaryPass.apply(to: delta, table: dictionary), enabled: fillerRemovalEnabled)
    let text = transformOutsideProtectedSpans(removal.text) { segment, isFinalSegment in
      let normalized = normalizePunctuation(segment)
      let marked = QuestionMarkPass.apply(to: normalized, completingSentence: completingSentence && isFinalSegment)
      return completingSentence ? SentencePunctuationPass.apply(to: marked, completingEnd: isFinalSegment) : marked
    }
    return FillerRemoval(text: text, removedCount: removal.removedCount)
  }

  /// 引用・コード・URL の外側だけに変換を適用する。
  private static func transformOutsideProtectedSpans(
    _ text: String, _ transform: (String, Bool) -> String
  ) -> String {
    let chars = Array(text)
    var result = ""
    var segment = ""
    var quotes: [Character] = []
    var backtickCount = 0
    var index = 0

    func flushSegment(isFinal: Bool) {
      guard !segment.isEmpty else { return }
      result += transform(segment, isFinal)
      segment = ""
    }

    while index < chars.count {
      let ch = chars[index]
      if backtickCount > 0 {
        let run = countRun(of: "`", in: chars, from: index)
        if run == backtickCount { backtickCount = 0 }
        result += String(chars[index..<(index + max(run, 1))])
        index += max(run, 1)
        continue
      }
      if quotes.isEmpty, ch == "`" {
        flushSegment(isFinal: false)
        backtickCount = countRun(of: "`", in: chars, from: index)
        result += String(chars[index..<(index + backtickCount)])
        index += backtickCount
        continue
      }
      if quotes.isEmpty, let urlEnd = urlEndIndex(in: chars, from: index) {
        flushSegment(isFinal: false)
        result += String(chars[index..<urlEnd])
        index = urlEnd
        continue
      }
      if let closing = quotePairs[ch], quotes.last != ch {
        if quotes.isEmpty { flushSegment(isFinal: false) }
        quotes.append(closing)
        result.append(ch)
      } else if quotes.last == ch {
        quotes.removeLast()
        result.append(ch)
      } else if quotes.isEmpty {
        segment.append(ch)
      } else {
        result.append(ch)
      }
      index += 1
    }
    flushSegment(isFinal: true)
    return result
  }

  private static func countRun(of target: Character, in chars: [Character], from start: Int) -> Int {
    var count = 0
    while start + count < chars.count, chars[start + count] == target {
      count += 1
    }
    return count
  }

  private static func urlEndIndex(in chars: [Character], from start: Int) -> Int? {
    let prefixes = [Array("https://"), Array("http://")]
    guard prefixes.contains(where: { start + $0.count <= chars.count && Array(chars[start..<(start + $0.count)]) == $0 })
    else { return nil }
    var end = start
    while end < chars.count, !chars[end].isWhitespace {
      end += 1
    }
    return end
  }

  private static func normalizePunctuation(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"(?<=[?!？！])[ 　]*[。、，]+|[。、，]+(?=[?!？！])|(?<=。)。+"#,
      with: "", options: .regularExpression)
  }
}

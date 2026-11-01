import Foundation

/// 会話の用語を認識時だけ渡す。辞書や本文を書き換えず、コード・ツール出力は使わない。
public enum SpeechVocabulary {
  public static func keywords(jsonLines: [String]) -> String {
    let turns = jsonLines.compactMap(message).suffix(12)
    var words: [String] = []
    var seen: Set<String> = []
    for turn in turns.reversed() {
      let prose = removing(#"```[\s\S]*?(?:```|$)|https?://\S+"#, from: turn)
      let text = removing(#"[A-Za-z0-9._~+-]*[/\\][A-Za-z0-9._~+/@%\\-]+"#, from: prose)
      let quoted = matches(#"`([\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9ー・+.-]{2,24})`"#, in: text, group: 1)
      let names = matches(#"(?<![A-Za-z0-9_/.-])[A-Z][A-Za-z0-9]*(?:[.+-][A-Za-z0-9]+)*(?![A-Za-z0-9_/.-])"#, in: text)
      for word in quoted + names where (2...32).contains(word.count) && !stopWords.contains(word) {
        guard seen.insert(word.lowercased()).inserted else { continue }
        words.append(word)
        if words.count == 12 { return words.joined(separator: "\n") }
      }
    }
    return words.joined(separator: "\n")
  }

  private static let stopWords: Set<String> = [
    "The", "This", "That", "These", "There", "Here", "Please", "Use", "You", "Your", "We", "It", "To", "For", "If", "When",
    "Yes", "No", "OK", "TODO", "NOTE", "WARNING", "IMPORTANT", "AGENTS.md", "SKILL.md", "README.md"
  ]

  private static func message(_ line: String) -> String? {
    guard let data = line.data(using: .utf8),
      let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let body: [String: Any]?
    switch record["type"] as? String {
    case "user", "assistant": body = record["message"] as? [String: Any]
    case "response_item": body = record["payload"] as? [String: Any]
    default: return nil
    }
    guard let body, ["user", "assistant"].contains(body["role"] as? String ?? "") else { return nil }
    if let text = body["content"] as? String { return text }
    let blocks = body["content"] as? [[String: Any]] ?? []
    let text = blocks.compactMap { block -> String? in
      guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
      return block["text"] as? String
    }.joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  private static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range(at: group), in: text).map { String(text[$0]) }
    }
  }

  private static func removing(_ pattern: String, from text: String) -> String {
    text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
  }
}

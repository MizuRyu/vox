// パレットの fuzzy 検索。外部ライブラリを足さない（指示書）。
//
// 方式は subsequence の貪欲一致 + 加点。パス全体に対する一致と、
// ファイル名の部分だけに閉じた一致を両方試して、点の高いほうを採る。
// 「このファイルの〜」と言いたい対象はファイル名で思い出すので、パス末尾の一致を強く優遇する。

import Foundation

public struct FuzzyMatchResult: Equatable, Sendable {
  public let score: Int
  /// 一致した位置（`path` の Character オフセット）。UI のハイライト用。
  public let matchedIndices: [Int]

  public init(score: Int, matchedIndices: [Int]) {
    self.score = score
    self.matchedIndices = matchedIndices
  }
}

public enum FuzzyMatch {
  /// 1 文字一致
  static let hitScore = 10
  /// 直前の文字と連続している
  static let consecutiveScore = 12
  /// ファイル名部分（最後の `/` より後ろ）での一致
  static let fileNameScore = 8
  /// 区切り文字の直後（語頭）での一致
  static let boundaryScore = 6

  private static let boundaries: Set<Character> = ["/", "_", "-", ".", " ", "+"]

  /// `query` が `path` の subsequence でなければ nil。
  /// 空クエリは「既定表示（変更ファイル）」の担当なのでここでは nil を返す。
  public static func match(query: String, path: String) -> FuzzyMatchResult? {
    guard !query.isEmpty, !path.isEmpty else { return nil }
    let haystack = Array(path.lowercased())
    let needle = Array(query.lowercased())
    guard needle.count <= haystack.count else { return nil }

    let fileNameStart = haystack.lastIndex(of: "/").map { $0 + 1 } ?? 0

    var best: FuzzyMatchResult?
    let starts = fileNameStart > 0 ? [0, fileNameStart] : [0]
    for start in starts {
      guard let indices = greedyIndices(needle, in: haystack, from: start) else { continue }
      let candidate = FuzzyMatchResult(
        score: score(indices, in: haystack, fileNameStart: fileNameStart),
        matchedIndices: indices)
      if best == nil || candidate.score > best!.score { best = candidate }
    }
    return best
  }

  private static func greedyIndices(
    _ needle: [Character], in haystack: [Character], from start: Int
  ) -> [Int]? {
    var indices: [Int] = []
    indices.reserveCapacity(needle.count)
    var cursor = start
    for character in needle {
      var found = false
      while cursor < haystack.count {
        if haystack[cursor] == character {
          indices.append(cursor)
          cursor += 1
          found = true
          break
        }
        cursor += 1
      }
      guard found else { return nil }
    }
    return indices
  }

  private static func score(_ indices: [Int], in haystack: [Character], fileNameStart: Int) -> Int {
    var total = 0
    var previous = -2
    for index in indices {
      total += hitScore
      if index == previous + 1 { total += consecutiveScore }
      if index >= fileNameStart { total += fileNameScore }
      if index == 0 || boundaries.contains(haystack[index - 1]) { total += boundaryScore }
      previous = index
    }
    // 同点のときは短いパス・前方一致を優先する。
    total -= haystack.count / 4
    total -= (indices.first ?? 0) / 8
    return total
  }
}

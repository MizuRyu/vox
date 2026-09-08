// B-4。計測・履歴・診断ログの `error` は分類の文字列（開発手順の表）だけを載せる契約。
// framework の説明文が混ざると集計できず、長さの上限も無くなる。

import Foundation
import Testing

@Suite("Session: error の分類")
struct ErrorContractTests {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// docs/development.md の `error` 表の左列。
  private func documentedValues() throws -> Set<String> {
    let document = try String(
      contentsOf: repositoryRoot.appendingPathComponent("docs/development.md"), encoding: .utf8)
    let row = /^\|\s*`([a-z_]+)`\s*\|/
    return Set(document.split(separator: "\n").compactMap { $0.firstMatch(of: row)?.1 }.map(String.init))
  }

  @Test("録音の error は表にある分類だけで、説明文を混ぜない")
  func recordedErrorsAreDocumentedClassifications() throws {
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/VoxApp/Session/App.swift"),
      encoding: .utf8)
    let documented = try documentedValues()
    let assignment = /error\??\s*[=:]\s*"([^"]*)"/
    var found = 0
    for match in source.matches(of: assignment) {
      let value = String(match.1)
      found += 1
      #expect(!value.contains("\\("), "error に説明文が混ざっている: \(value)")
      #expect(documented.contains(value), "開発手順の表に無い error: \(value)")
    }
    #expect(found > 0, "error の代入を 1 つも読み取れなかった")
  }
}

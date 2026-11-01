import Foundation
import Testing
import VoxCore

@Suite("Session vocabulary: 少数の用語だけを取り出す")
struct SpeechVocabularyTests {
  @Test("会話の表記をヒントへ渡し、URL・パス・コード・ツール出力は含めない")
  func extractsTerms() {
    let lines = [
      #"{"type":"user","message":{"role":"user","content":"HaasとOrcaで比較したい"}}"#,
      #"{"type":"assistant","message":{"role":"assistant","content":"Haas、Orcaと`従量課金`を確認します。https://Example.com /workspace/Private/Token SOME_TOKEN"}}"#,
      #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","input":{"command":"SecretValue"}}]}}"#,
      #"{"type":"response_item","payload":{"type":"message","role":"tool","content":[{"type":"output_text","text":"PrivateValue"}]}}"#
    ]
    let words = SpeechVocabulary.keywords(jsonLines: lines).split(separator: "\n").map(String.init)
    #expect(words.contains("Haas") && words.contains("Orca") && words.contains("従量課金"))
    #expect(!words.contains(where: { $0.contains("Private") || $0.contains("Secret") || $0.contains("TOKEN") || $0 == "Example" }))
  }

  @Test("Codexの本文だけを読み、少数・重複なし・直近優先にする")
  func boundedRecentTerms() {
    let lines = (0..<100).map {
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Model\#($0)"}]}}"#
    }
    let words = SpeechVocabulary.keywords(jsonLines: lines).split(separator: "\n")
    #expect(words.count <= 12 && Set(words).count == words.count)
    #expect(words.contains("Model99") && !words.contains("Model0"))
    #expect(SpeechVocabulary.keywords(jsonLines: ["broken", "{}"]).isEmpty)
  }
}

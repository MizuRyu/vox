// 検査で繰り返し使う組み立てと突き合わせ。失敗位置は呼び出し側に出す。

import Darwin
import Foundation
import Testing
import VoxCore

/// 使い捨ての作業ディレクトリ。呼び出し側が消す。
func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// symlink・hardlink・FIFO を `root` に用意し、渡した操作がどれも拒否して、
/// リンクの先にある被害者ファイルを 1 バイトも変えないことを見る。
func expectRejectsUnsafeTargets(
  in root: URL, _ operation: (URL) throws -> Void,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let manager = FileManager.default
  let victim = root.appendingPathComponent("victim")
  try Data("keep".utf8).write(to: victim)
  let symbolic = root.appendingPathComponent("symbolic")
  try manager.createSymbolicLink(at: symbolic, withDestinationURL: victim)
  // Check the symlink before the hard link below raises victim's st_nlink to 2 —
  // otherwise the nlink check alone would reject it even without O_NOFOLLOW.
  #expect(
    throws: (any Error).self, "unsafe target refused: \(symbolic.lastPathComponent)",
    sourceLocation: sourceLocation
  ) {
    try operation(symbolic)
  }
  let hard = root.appendingPathComponent("hard")
  try manager.linkItem(at: victim, to: hard)
  let fifo = root.appendingPathComponent("fifo")
  #expect(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture created", sourceLocation: sourceLocation)
  for candidate in [hard, fifo] {
    #expect(
      throws: (any Error).self, "unsafe target refused: \(candidate.lastPathComponent)",
      sourceLocation: sourceLocation
    ) {
      try operation(candidate)
    }
  }
  #expect(
    try Data(contentsOf: victim) == Data("keep".utf8),
    "unsafe targets were not modified", sourceLocation: sourceLocation)
}

/// fuzzy の順位は「どちらが上か」でしか意味を持たないので、点そのものではなく順位を検証する。
func expectRanksHigher(query: String, better: String, worse: String) throws {
  let betterMatch = try #require(
    FuzzyMatch.match(query: query, path: better), "\(query) が \(better) に一致しない")
  let worseMatch = try #require(
    FuzzyMatch.match(query: query, path: worse), "\(query) が \(worse) に一致しない")
  #expect(
    betterMatch.score > worseMatch.score,
    "\(query): \(better)=\(betterMatch.score) が \(worse)=\(worseMatch.score) を上回らない")
}

/// 1 回分の計測。既定は「貼り付けもパレットも起きなかった回」で、
/// 検査は自分が主張するフィールドだけ渡す。
func sampleMetrics(
  firstTokenMilliseconds: Double? = nil, paletteOpenedCount: Int = 0,
  paletteOpenMilliseconds: Double? = nil, paletteTargetSource: String? = nil,
  pastedCharacters: Int? = nil, readbackCharacters: Int? = nil
) -> MetricsRecord {
  MetricsRecord(
    toggleOnMilliseconds: 100, analyzerStartMilliseconds: 150, speechOnsetMilliseconds: nil,
    firstResultMilliseconds: nil, toggleOffMilliseconds: 900, finalizedMilliseconds: 1000,
    pastePostedMilliseconds: nil, pasteReceivedMilliseconds: nil, axisAMilliseconds: nil,
    firstTokenMilliseconds: firstTokenMilliseconds, finalTextLength: 0, targetApp: nil, error: nil,
    targetActivateMilliseconds: nil, fillerRemovedCount: 0, typedCharacters: 0,
    modifierWaitMilliseconds: 0, paletteOpenedCount: paletteOpenedCount,
    paletteOpenMilliseconds: paletteOpenMilliseconds, paletteTargetSource: paletteTargetSource,
    pastedCharacters: pastedCharacters, readbackCharacters: readbackCharacters)
}

func encodeToObject(_ value: some Encodable) throws -> [String: Any] {
  let data = try JSONEncoder().encode(value)
  return try #require(
    try JSONSerialization.jsonObject(with: data) as? [String: Any], "JSON オブジェクトにならない")
}

func expect(
  _ buffer: TranscriptBuffer, head: String, tentative: String, tail: String = "",
  caret: Int, sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(buffer.head == head, "head", sourceLocation: sourceLocation)
  #expect(buffer.tentative == tentative, "tentative", sourceLocation: sourceLocation)
  #expect(buffer.tail == tail, "tail", sourceLocation: sourceLocation)
  #expect(buffer.caret == caret, "caret", sourceLocation: sourceLocation)
}

func expect(
  _ result: TranscriptAppend, text: String, caret: Int,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(result.text == text, "text", sourceLocation: sourceLocation)
  #expect(result.caret == caret, "caret", sourceLocation: sourceLocation)
}

func expect(
  _ decision: SigilTriggerDecision, _ expected: SigilTriggerDecision,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(decision == expected, "判定", sourceLocation: sourceLocation)
}

func expect(
  _ plan: PaletteInsertionPlan, text: String, caret: Int,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(plan.text == text, "text", sourceLocation: sourceLocation)
  #expect(plan.caret == caret, "caret", sourceLocation: sourceLocation)
}

func expect(
  _ result: FillerRemoval, _ text: String, _ removedCount: Int,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(result.text == text, "text", sourceLocation: sourceLocation)
  #expect(result.removedCount == removedCount, "removedCount", sourceLocation: sourceLocation)
}

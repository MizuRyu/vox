import Foundation
import SQLite3
import Testing
@testable import VoxApp

@Suite("Session vocabulary: 入力先と期限を守る")
struct SessionVocabularyTests {
  @Test("Codexの索引を読み取り専用で使い、別フォルダ・期限切れ・長い行を除外する")
  func codexIndexAndBoundedTail() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("vox-vocabulary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent(".codex/sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.jsonl")
    let message = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"HaasとOrcaを比較します"}]}}"#
    try Data((String(repeating: "あ", count: 100000) + "\n" + message + "\n").utf8).write(to: file)
    var database: OpaquePointer?
    #expect(sqlite3_open(home.appendingPathComponent(".codex/state_5.sqlite").path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    let created = sqlite3_exec(database,
      "CREATE TABLE threads (rollout_path TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, agent_role TEXT)", nil, nil, nil)
    #expect(created == SQLITE_OK)
    let stamp = Int(Date().timeIntervalSince1970)
    let alias = FileManager.default.fileExists(atPath: file.path.lowercased()) ? file.path.lowercased() : file.path
    let path = alias.replacingOccurrences(of: "'", with: "''")
    #expect(sqlite3_exec(database,
      "INSERT INTO threads VALUES ('\(path)', '/workspace/demo', \(stamp), 0, NULL)", nil, nil, nil) == SQLITE_OK)
    #expect(SessionVocabulary.keywords(root: "/workspace/demo", home: home, now: Date()).contains("Haas"))
    #expect(SessionVocabulary.keywords(root: "/workspace/other", home: home, now: Date()).isEmpty)
    #expect(SessionVocabulary.keywords(root: "/workspace/demo", home: home, now: Date().addingTimeInterval(16 * 60)).isEmpty)
  }

  @Test("一致するセッションだけを使い、古いものと並行セッションは混ぜない")
  func scopeAndExpiry() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("vox-vocabulary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let root = "/workspace/demo"
    let folder = home.appendingPathComponent(".claude/projects/-workspace-demo")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let one = folder.appendingPathComponent("\(UUID()).jsonl")
    let text = #"{"type":"assistant","cwd":"/workspace/demo","message":{"role":"assistant","content":"HaasとOrcaを確認します"}}"#
    try Data((text + "\n").utf8).write(to: one)
    #expect(SessionVocabulary.keywords(root: root, home: home, now: Date()).contains("Haas"))
    #expect(SessionVocabulary.keywords(root: "/workspace/other", home: home, now: Date()).isEmpty)
    #expect(SessionVocabulary.keywords(root: root, home: home, now: Date().addingTimeInterval(16 * 60)).isEmpty)
    let two = folder.appendingPathComponent("\(UUID()).jsonl")
    try Data((text + "\n").utf8).write(to: two)
    #expect(SessionVocabulary.keywords(root: root, home: home, now: Date()).isEmpty)
  }
}

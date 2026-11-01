import Darwin
import Foundation
import SQLite3
import VoxCore

/// 入力先と同じフォルダの直近セッションが1つだけのとき、用語を録音開始時に固定する。
enum SessionVocabulary {
  static func resolve(bundleIdentifier: String?, processID: Int32?) async -> String {
    let started = voxNowMilliseconds()
    defer { voxLog("speech_vocabulary elapsed_ms=\(Int(voxNowMilliseconds() - started))") }
    guard PaletteTargetAdapter.forBundleIdentifier(bundleIdentifier) != .none else {
      voxLog("speech_vocabulary status=unsupported count=0")
      return ""
    }
    guard let target = await PaletteTargetResolver.resolve(
      bundleIdentifier: bundleIdentifier, processID: processID, fallbackRepositories: [], recentFolder: nil,
      budgetMilliseconds: 1500), target.source.resolvedFromFrontmostApp
    else {
      voxLog("speech_vocabulary status=target_unavailable count=0")
      return ""
    }
    return keywords(root: target.root, home: FileManager.default.homeDirectoryForCurrentUser, now: Date())
  }

  static func keywords(root: String, home: URL, now: Date) -> String {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
    let since = now.addingTimeInterval(-15 * 60)
    let claude = claudeCandidates(root: root, home: home, since: since, deadline: deadline)
    let codex = codexCandidates(root: root, home: home, since: since, deadline: deadline)
    let candidates = claude + codex
    // 同じリポジトリの並行セッションを、更新時刻だけで選ばない。
    guard ContinuousClock.now < deadline else {
      voxLog("speech_vocabulary status=timeout count=0")
      return ""
    }
    guard candidates.count == 1, let file = candidates.first, let lines = tail(file) else {
      voxLog("speech_vocabulary status=\(candidates.count > 1 ? "ambiguous" : "no_session") count=0")
      return ""
    }
    let terms = SpeechVocabulary.keywords(jsonLines: lines)
    let count = terms.split(separator: "\n").count
    voxLog("speech_vocabulary status=\(terms.isEmpty ? "no_terms" : "ready") count=\(count)")
    return terms
  }

  private static func claudeCandidates(
    root: String, home: URL, since: Date, deadline: ContinuousClock.Instant
  ) -> [URL] {
    let project = root.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    let directory = home.appendingPathComponent(".claude/projects/\(project)")
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
    var candidates: [URL] = []
    for file in files where file.pathExtension == "jsonl" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
      guard ContinuousClock.now < deadline else { return [] }
      guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let modified = values.contentModificationDate, modified >= since,
        let lines = tail(file), belongsToRoot(lines, root: root)
      else { continue }
      candidates.append(file)
      if candidates.count == 2 { break }
    }
    return candidates
  }

  private static func belongsToRoot(_ lines: [String], root: String) -> Bool {
    let directories = lines.compactMap { line -> String? in
      guard let data = line.data(using: .utf8),
        let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { return nil }
      return record["cwd"] as? String
    }
    return !directories.isEmpty && directories.allSatisfy { $0 == root }
  }

  private static func codexCandidates(
    root: String, home: URL, since: Date, deadline: ContinuousClock.Instant
  ) -> [URL] {
    let directory = home.appendingPathComponent(".codex")
    let databases = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
      .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    guard let name = databases.first, ContinuousClock.now < deadline else { return [] }
    var database: OpaquePointer?
    guard sqlite3_open_v2(directory.appendingPathComponent(name).path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(database)
      return []
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 20)
    let sql = "SELECT rollout_path FROM threads WHERE cwd = ? AND updated_at >= ? AND archived = 0 AND agent_role IS NULL LIMIT 2"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, root, -1, transient)
    sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970))
    let allowed = directory.appendingPathComponent("sessions").resolvingSymlinksInPath()
    var files: [URL] = []
    while ContinuousClock.now < deadline, sqlite3_step(statement) == SQLITE_ROW {
      guard let value = sqlite3_column_text(statement, 0) else { continue }
      let file = URL(fileURLWithPath: String(cString: value)).resolvingSymlinksInPath()
      var relationship = FileManager.URLRelationship.other
      // macOS のホームは、ログと OS が返すパスで英字の大小が異なることがある。
      guard (try? FileManager.default.getRelationship(&relationship, ofDirectoryAt: allowed, toItemAt: file)) != nil,
        relationship == .contains, file.pathExtension == "jsonl"
      else { continue }
      files.append(file)
    }
    return files
  }

  private static func tail(_ file: URL) -> [String]? {
    let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let offset = max(0, info.st_size - 256 * 1024)
    do {
      try handle.seek(toOffset: UInt64(offset))
      let data = try handle.read(upToCount: 256 * 1024) ?? Data()
      // 末尾読み出しは UTF-8 の途中から始まる。最初の行を落としてから復号する。
      let complete = offset > 0 ? data.drop(while: { $0 != 10 }).dropFirst() : data[...]
      guard let text = String(data: Data(complete), encoding: .utf8) else { return nil }
      return text.split(separator: "\n").map(String.init)
    } catch { return nil }
  }
}

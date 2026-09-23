// T23 最近使ったフォルダ。並び・上限・絞り込みと JSON の往復。

import Foundation
import Testing
import VoxCore

@Suite("Palette: 最近使ったフォルダ")
struct FolderHistoryTests {
  /// 秒までの分解能で保存するので、検査の時刻も秒で置く。
  private func at(_ offset: Double) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
  }

  private func history(_ paths: [(String, Double)]) -> FolderHistory {
    FolderHistory(
      entries: paths.map { FolderHistoryEntry(path: $0.0, lastUsedAt: at($0.1), useCount: 1) })
  }

  // MARK: 記録

  @Test("Recording A folder puts it at the head with its basename")
  func recordingAFolderPutsItAtTheHeadWithItsBasename() throws {
    var folders = history([("/repos/old", 0)])
    folders.record("/repos/vox", at: at(10))
    #expect(folders.entries.map(\.path) == ["/repos/vox", "/repos/old"], "先頭に入っていない")
    let head = try #require(folders.entries.first)
    #expect(head.name == "vox", "表示名が basename になっていない: \(head.name)")
    #expect(head.useCount == 1, "初回の回数が 1 でない: \(head.useCount)")
  }

  @Test("Recording the same folder counts up instead of duplicating")
  func recordingTheSameFolderCountsUpInsteadOfDuplicating() throws {
    var folders = history([("/repos/vox", 0), ("/repos/other", 5)])
    folders.record("/repos/vox", at: at(10))
    #expect(folders.entries.count == 2, "同じフォルダが重複した: \(folders.entries.map(\.path))")
    let head = try #require(folders.entries.first)
    #expect(head.path == "/repos/vox", "使い直したフォルダが先頭に来ていない: \(head.path)")
    #expect(head.useCount == 2, "回数が足されていない: \(head.useCount)")
  }

  @Test("Recording normalizes A trailing slash into the same folder")
  func recordingNormalizesATrailingSlashIntoTheSameFolder() throws {
    var folders = FolderHistory()
    folders.record("/repos/vox", at: at(0))
    folders.record("/repos/vox/", at: at(10))
    folders.record("/repos/vox/Sources/..", at: at(20))
    #expect(folders.entries.map(\.path) == ["/repos/vox"], "同じフォルダを別々に数えた: \(folders.entries)")
    #expect(folders.entries.first?.useCount == 3, "正規化した回の回数が足されていない")
  }

  @Test("Recording an empty path changes nothing")
  func recordingAnEmptyPathChangesNothing() throws {
    var folders = history([("/repos/vox", 0)])
    folders.record("", at: at(10))
    #expect(folders.entries.map(\.path) == ["/repos/vox"], "空のパスを記録した: \(folders.entries)")
  }

  // MARK: 上限と並び

  @Test("The limit drops the least recently used folder")
  func theLimitDropsTheLeastRecentlyUsedFolder() throws {
    var folders = FolderHistory(
      entries: (0..<FolderHistory.limit).map {
        FolderHistoryEntry(path: "/repos/f\($0)", lastUsedAt: at(Double($0)), useCount: 1)
      })
    #expect(folders.entries.count == FolderHistory.limit, "上限ぶん入っていない")
    folders.record("/repos/new", at: at(100))
    #expect(folders.entries.count == FolderHistory.limit, "上限を超えた: \(folders.entries.count)")
    #expect(folders.entries.first?.path == "/repos/new", "新しいフォルダが先頭にない")
    #expect(
      !folders.entries.contains { $0.path == "/repos/f0" },
      "最後に使った時刻が最も古いフォルダが落ちていない")
  }

  @Test("Entries are ordered by the last use even when constructed out of order")
  func entriesAreOrderedByTheLastUseEvenWhenConstructedOutOfOrder() throws {
    let folders = history([("/repos/a", 10), ("/repos/b", 30), ("/repos/c", 20)])
    #expect(
      folders.entries.map(\.path) == ["/repos/b", "/repos/c", "/repos/a"],
      "最後に使った時刻の新しい順になっていない: \(folders.entries.map(\.path))")
  }

  // MARK: 掃除

  @Test("Pruning drops folders that no longer exist")
  func pruningDropsFoldersThatNoLongerExist() throws {
    let folders = history([("/repos/gone", 20), ("/repos/vox", 10)])
    let kept = folders.pruned { $0 == "/repos/vox" }
    #expect(kept.entries.map(\.path) == ["/repos/vox"], "消えたフォルダが残った: \(kept.entries)")
  }

  // MARK: 候補

  @Test("Candidates exclude the current search target")
  func candidatesExcludeTheCurrentSearchTarget() throws {
    let folders = history([("/repos/vox", 30), ("/repos/other", 20), ("/repos/third", 10)])
    let rows = folders.candidates(matching: "", excluding: "/repos/vox/", limit: 3)
    #expect(
      rows.map(\.path) == ["/repos/other", "/repos/third"],
      "今の検索対象を候補に出した: \(rows.map(\.path))")
  }

  @Test("Candidates stop at the limit")
  func candidatesStopAtTheLimit() throws {
    let folders = history([("/repos/a", 40), ("/repos/b", 30), ("/repos/c", 20), ("/repos/d", 10)])
    let rows = folders.candidates(matching: "", excluding: nil, limit: 3)
    #expect(
      rows.map(\.path) == ["/repos/a", "/repos/b", "/repos/c"],
      "上限 3 件を超えた、または並びが違う: \(rows.map(\.path))")
  }

  @Test("A query narrows candidates by path, ignoring case")
  func aQueryNarrowsCandidatesByPathIgnoringCase() throws {
    let folders = history([("/repos/Vox", 30), ("/repos/other", 20), ("/work/voxel", 10)])
    let rows = folders.candidates(matching: "vox", excluding: nil, limit: FolderHistory.limit)
    #expect(
      rows.map(\.path) == ["/repos/Vox", "/work/voxel"],
      "部分一致で絞れていない: \(rows.map(\.path))")
  }

  @Test("A query still excludes the current search target")
  func aQueryStillExcludesTheCurrentSearchTarget() throws {
    let folders = history([("/repos/vox", 30), ("/work/voxel", 10)])
    let rows = folders.candidates(
      matching: "vox", excluding: "/repos/vox", limit: FolderHistory.limit)
    #expect(rows.map(\.path) == ["/work/voxel"], "検索対象が候補に残った: \(rows.map(\.path))")
  }

  @Test("A query with no match leaves no candidates")
  func aQueryWithNoMatchLeavesNoCandidates() throws {
    let folders = history([("/repos/vox", 30), ("/repos/other", 20)])
    let rows = folders.candidates(
      matching: "zzz", excluding: nil, limit: FolderHistory.limit)
    #expect(rows.isEmpty, "一致しないクエリで候補が出た: \(rows.map(\.path))")
  }

  // MARK: JSON

  @Test("JSON round trip keeps the folders")
  func jsonRoundTripKeepsTheFolders() throws {
    var folders = FolderHistory()
    folders.record("/repos/vox", at: at(10))
    folders.record("/repos/other", at: at(20))
    folders.record("/repos/vox", at: at(30))
    let restored = FolderHistory.decoded(from: try folders.encoded())
    #expect(
      restored.entries.map(\.path) == ["/repos/vox", "/repos/other"],
      "JSON の往復で並びが変わった: \(restored.entries.map(\.path))")
    #expect(
      restored.entries.map(\.useCount) == [2, 1], "回数が往復で変わった: \(restored.entries)")
    #expect(restored.entries.first?.lastUsedAt == at(30), "時刻が往復で変わった")
    #expect(restored == folders, "JSON の往復で中身が変わった: \(restored.entries)")
  }

  @Test("Broken JSON reads as an empty history")
  func brokenJSONReadsAsAnEmptyHistory() throws {
    let folders = FolderHistory.decoded(from: Data("{ not json".utf8))
    #expect(folders.entries.isEmpty, "壊れたファイルから中身を作った: \(folders.entries)")
  }

  @Test("An unknown schema version reads as an empty history")
  func anUnknownSchemaVersionReadsAsAnEmptyHistory() throws {
    let data = Data(
      """
      {"schema_version":99,"folders":[{"path":"/repos/vox","last_used_at":"2026-09-23T00:00:00Z","use_count":1}]}
      """.utf8)
    #expect(
      FolderHistory.decoded(from: data).entries.isEmpty, "知らない版のファイルを読み込んだ")
  }
}

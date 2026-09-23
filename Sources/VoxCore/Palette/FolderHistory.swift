// T23。検索対象として最近使ったフォルダ。パレットから確定した回に記録し、候補行に出す。
// 保存先の決定とファイル IO は VoxApp（FolderHistoryStore）。ここは並び・上限・絞り込みだけ。

import Foundation

public struct FolderHistoryEntry: Codable, Equatable, Sendable {
  /// 絶対パス。末尾の `/` や `..` は畳んで入れる（同じフォルダを二重に数えないため）。
  public let path: String
  public let lastUsedAt: Date
  public let useCount: Int

  /// 候補行に出す表示名。パスから導けるので保存しない。
  public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

  public init(path: String, lastUsedAt: Date, useCount: Int) {
    self.path = path
    self.lastUsedAt = lastUsedAt
    self.useCount = useCount
  }

  private enum CodingKeys: String, CodingKey {
    case path
    case lastUsedAt = "last_used_at"
    case useCount = "use_count"
  }
}

public struct FolderHistory: Equatable, Sendable {
  /// 溢れたら最後に使った時刻が古い順に落とす。
  public static let limit = 20
  /// 形式の版。読めない版のファイルは空として扱う（原本は書き換えるまで残る）。
  private static let schemaVersion = 1

  /// 最後に使った時刻の新しい順。
  public private(set) var entries: [FolderHistoryEntry]

  public init(entries: [FolderHistoryEntry] = []) {
    // 並びと上限はここで正す。時刻が同じ回はパスで決める（同じ入力なら同じ並びにする）。
    self.entries = Array(
      entries.sorted {
        $0.lastUsedAt == $1.lastUsedAt ? $0.path < $1.path : $0.lastUsedAt > $1.lastUsedAt
      }.prefix(Self.limit))
  }

  /// パレットから確定した回に呼ぶ。同じフォルダは回数を足して先頭へ移す。
  public mutating func record(_ path: String, at date: Date) {
    let key = FilePathFormat.standardized(path)
    guard !key.isEmpty else { return }
    let previous = entries.first { $0.path == key }
    let entry = FolderHistoryEntry(
      path: key, lastUsedAt: date, useCount: (previous?.useCount ?? 0) + 1)
    self = FolderHistory(entries: [entry] + entries.filter { $0.path != key })
  }

  /// 候補行に出すフォルダ。`query` があればパスの部分一致で絞る。今の検索対象は出さない。
  public func candidates(matching query: String, excluding currentRoot: String?, limit: Int)
    -> [FolderHistoryEntry] {
    let current = currentRoot.map(FilePathFormat.standardized)
    let term = query.lowercased()
    let matched = entries.filter { entry in
      entry.path != current && (term.isEmpty || entry.path.lowercased().contains(term))
    }
    return Array(matched.prefix(max(0, limit)))
  }

  /// 読み込み時の掃除。消えたフォルダを落とす（存在の確認は呼び出し側）。
  public func pruned(exists: (String) -> Bool) -> FolderHistory {
    FolderHistory(entries: entries.filter { exists($0.path) })
  }

  /// 保存する形。フィールド名は history.jsonl と同じ snake_case。
  private struct Stored: Codable {
    let schemaVersion: Int
    let folders: [FolderHistoryEntry]

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case folders
    }
  }

  /// 壊れたファイルと知らない版は空として読む（落とさない）。
  public static func decoded(from data: Data) -> FolderHistory {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let stored = try? decoder.decode(Stored.self, from: data),
      stored.schemaVersion == schemaVersion
    else { return FolderHistory() }
    return FolderHistory(entries: stored.folders)
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(Stored(schemaVersion: Self.schemaVersion, folders: entries))
  }
}

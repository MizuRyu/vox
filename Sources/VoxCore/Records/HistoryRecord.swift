// R17 ローカル履歴の 1 行。確定テキストを挿入の成否に関わらず残す。
// M1 の実測で 437 文字の挿入結果が行方不明になった事例が根拠（設計書 §1 R17）。
// 書き込み先の決定と I/O は Vox 側（HistoryWriter）。ここは直列化だけ。

import Foundation

public struct HistoryRecord: Codable, Sendable {
  public static let schemaVersion = 1

  /// ISO 8601（ローカル時刻）。
  public var at: String
  /// フィラー除去前の確定テキスト。除去が誤っても元に戻せるように残す（ADR-012）。
  public var rawText: String?
  /// クリップボードへ載せて `Cmd+V` を送ったテキスト。送らなかったら nil。
  public var insertedText: String?
  public var targetApp: String?
  /// 受領証まで確認できたときだけ true。
  public var inserted: Bool
  public var error: String?
  /// ユーザーが打った文字を含むか。
  public var edited: Bool

  public init(
    at: String, rawText: String?, insertedText: String?, targetApp: String?, inserted: Bool,
    error: String?, edited: Bool
  ) {
    self.at = at
    self.rawText = rawText
    self.insertedText = insertedText
    self.targetApp = targetApp
    self.inserted = inserted
    self.error = error
    self.edited = edited
  }

  public enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case at
    case rawText = "raw_text"
    case insertedText = "inserted_text"
    case targetApp = "target_app"
    case inserted
    case error
    case edited
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    at = try container.decode(String.self, forKey: .at)
    rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
    insertedText = try container.decodeIfPresent(String.self, forKey: .insertedText)
    targetApp = try container.decodeIfPresent(String.self, forKey: .targetApp)
    inserted = try container.decodeIfPresent(Bool.self, forKey: .inserted) ?? false
    error = try container.decodeIfPresent(String.self, forKey: .error)
    edited = try container.decodeIfPresent(Bool.self, forKey: .edited) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(at, forKey: .at)
    try container.encodeAlways(rawText, forKey: .rawText)
    try container.encodeAlways(insertedText, forKey: .insertedText)
    try container.encodeAlways(targetApp, forKey: .targetApp)
    try container.encode(inserted, forKey: .inserted)
    try container.encodeAlways(error, forKey: .error)
    try container.encode(edited, forKey: .edited)
  }
}

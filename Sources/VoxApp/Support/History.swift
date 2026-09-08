// R17 ローカル履歴の書き出しと読み出し。1 確定 1 行。
// 私的データなのでリポジトリ外（~/Library/Application Support/vox/history.jsonl）に置く。
// 行の形（キーと null の扱い）は VoxCore.HistoryRecord が持つ。

import Foundation
import VoxCore

enum HistoryStore {
  /// 既定パス。ディレクトリが無ければ書き込み時に作る。
  static var defaultPath: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("vox/history.jsonl").path
  }

  /// ISO 8601（ローカル時刻）。ISO8601DateFormatter は Sendable ではないので毎回作る（1 確定に 1 回）。
  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone.current
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}

/// JSONL への 1 行追記。書き込み失敗は stderr に出すだけで、入力操作は止めない（MetricsWriter と同じ方針）。
final class HistoryWriter {
  private let url: URL
  private let encoder: JSONEncoder

  init(path: String) {
    self.url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
  }

  var displayPath: String { url.path }

  func append(_ record: HistoryRecord) {
    do {
      try PrivateFileSafety.prepareForAppend(url)
      guard let line = String(data: try encoder.encode(record), encoding: .utf8) else {
        voxLog("history_error encoding_failed")
        return
      }
      let data = Data((line + "\n").utf8)
      try PrivateFileIO.append(data, to: url)
      voxLog("history_appended inserted=\(record.inserted) error=\(record.error ?? "-")")
    } catch {
      voxLog("history_error \(String(describing: error))")
    }
  }
}

/// `--print-history [n]`。末尾 n 件を人が読める形で出す。
enum HistoryPrinter {
  private static let maximumReadBytes = 1024 * 1024

  static func print(path: String, limit: Int) -> Int32 {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let tailRead = try? PrivateFileIO.readTail(url, maximumBytes: maximumReadBytes),
      let contents = String(data: tailRead.data, encoding: .utf8)
    else {
      voxWrite(Data("履歴がありません: \(url.path)\n".utf8), to: .standardError)
      return 0
    }
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
    let decoder = JSONDecoder()
    let records = lines.compactMap { line -> HistoryRecord? in
      try? decoder.decode(HistoryRecord.self, from: Data(line.utf8))
    }
    let tail = records.suffix(max(0, limit))
    let countDescription = tailRead.truncated
      ? "全件数不明・末尾 \(maximumReadBytes / 1024) KiB から \(tail.count) 件"
      : "\(records.count) 件中 \(tail.count) 件"
    Swift.print("history: \(url.path) (\(countDescription))")
    for (offset, record) in tail.enumerated() {
      let number = tail.count - offset
      let status = HistoryInsertionStatus.text(verified: record.inserted)
      let edited = record.edited ? " 編集あり" : ""
      Swift.print(
        "\n[\(number)] \(record.at)  \(status)\(edited)  target=\(record.targetApp ?? "-")"
          + "  error=\(record.error ?? "-")")
      let raw = record.rawText ?? ""
      if let inserted = record.insertedText, inserted != raw {
        Swift.print("  inserted: \(display(inserted))")
        Swift.print("  raw     : \(display(raw))")
      } else {
        Swift.print("  text    : \(display(raw))")
      }
    }
    return 0
  }

  private static func display(_ text: String) -> String {
    text.isEmpty ? "(空)" : text.replacingOccurrences(of: "\n", with: "\\n")
  }
}

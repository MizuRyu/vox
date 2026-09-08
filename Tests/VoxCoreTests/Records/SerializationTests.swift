// 計測・履歴レコードの直列化。

import Foundation
import Testing
import VoxCore

@Suite("Records: JSONL の直列化")
struct SerializationTests {
  @Test("Metrics record always writes twenty three keys")
  func metricsRecordAlwaysWritesTwentyThreeKeys() throws {
    let object = try encodeToObject(sampleMetrics())
    #expect(object.count == 23, "計測 JSONL のキー数が 23 でない: \(object.count)")
    #expect(MetricsRecord.CodingKeys.allCases.count == MetricsRecord.keyCount, "CodingKeys と keyCount が食い違う")
    #expect(object["schema_version"] as? Int == 5, "schema_version が 5 でない")
    for key in [
      "target_activate_ms", "filler_removed_count", "typed_chars", "modifier_wait_ms",
      "palette_opened_count", "palette_open_ms", "palette_target_source",
      "pasted_chars", "readback_chars"
    ] {
      #expect(object[key] != nil, "\(key) が無い")
    }
  }

  /// 欠損はキーを落とすのではなく null で出す（M0 からの JSONL 契約）。
  @Test("Metrics record writes null for missing values")
  func metricsRecordWritesNullForMissingValues() throws {
    let object = try encodeToObject(sampleMetrics())
    #expect(object.count == 23, "欠損時にキーが落ちた")
    #expect(
      object["axis_a_ms"] is NSNull && object["error"] is NSNull
        && object["palette_open_ms"] is NSNull && object["palette_target_source"] is NSNull
        && object["pasted_chars"] is NSNull && object["readback_chars"] is NSNull,
      "欠損値が null になっていない")
  }

  /// T19。挿入の欠落に気づくための長さ。置いた文字数と読み返した文字数がそのまま出る。
  @Test("Metrics record carries paste lengths")
  func metricsRecordCarriesPasteLengths() throws {
    let object = try encodeToObject(sampleMetrics(pastedCharacters: 843, readbackCharacters: 460))
    #expect((object["pasted_chars"] as? Int == 843) && (object["readback_chars"] as? Int == 460), "pasted_chars / readback_chars が出ていない")
  }

  /// T22。パレットを開いてから閉じるまでの時間。`palette_resume_ms` を置き換えた。
  @Test("Metrics record carries palette open duration")
  func metricsRecordCarriesPaletteOpenDuration() throws {
    let object = try encodeToObject(
      sampleMetrics(
        paletteOpenedCount: 1, paletteOpenMilliseconds: 4820, paletteTargetSource: "orca"))
    #expect(object["palette_open_ms"] as? Double == 4820, "palette_open_ms が出ていない")
    #expect(object["palette_resume_ms"] == nil, "廃止した palette_resume_ms が残っている")
  }

  /// T15。発話開始の検出が結果より遅れた回の初出遅延は無効なので null にする。
  @Test("Negative first token becomes null")
  func negativeFirstTokenBecomesNull() throws {
    // 発話開始 3000ms が結果 238ms より遅れて検出された回の差。
    let record = sampleMetrics(firstTokenMilliseconds: 238 - 3000)
    #expect(record.firstTokenMilliseconds == nil, "負の first_token_ms が残った")
    let object = try encodeToObject(record)
    #expect(object["first_token_ms"] is NSNull, "負の first_token_ms が null になっていない")
  }

  @Test("History record writes every key including nulls")
  func historyRecordWritesEveryKeyIncludingNulls() throws {
    let record = HistoryRecord(
      at: "2026-09-02T12:00:00+09:00", rawText: "", insertedText: nil, targetApp: nil,
      inserted: false, error: "empty_text", edited: false)
    let object = try encodeToObject(record)
    #expect(object.count == HistoryRecord.CodingKeys.allCases.count, "履歴のキー数が違う: \(object.count)")
    #expect(
      object["schema_version"] as? Int == 1
        && object["error"] as? String == "empty_text"
        && object["inserted"] as? Bool == false
        && object["inserted_text"] is NSNull
        && object["target_app"] is NSNull
        && object["raw_text"] as? String == "",
      "empty_text の行の中身が違う")
  }

  @Test("History record round trips through JSON")
  func historyRecordRoundTripsThroughJSON() throws {
    let record = HistoryRecord(
      at: "2026-09-02T12:00:00+09:00", rawText: "えっと、テストです", insertedText: "テストです",
      targetApp: "com.apple.TextEdit", inserted: true, error: nil, edited: true)
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(HistoryRecord.self, from: data)
    #expect(
      decoded.rawText == "えっと、テストです"
        && decoded.insertedText == "テストです"
        && decoded.targetApp == "com.apple.TextEdit"
        && decoded.inserted
        && decoded.edited
        && decoded.error == nil
        && decoded.at == record.at,
      "履歴の往復で値が変わった")
  }
}

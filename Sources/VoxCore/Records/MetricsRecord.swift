// 軸 A（発話終了 → 挿入完了）の計測 1 行。schema_version 5。
// 土台は指示書 T8 の表で、M2 で 4 フィールド（target_activate_ms / filler_removed_count /
// typed_chars / modifier_wait_ms）、M3 で 3 フィールド（palette_opened_count /
// palette_open_ms / palette_target_source）、T19 で 2 フィールド（pasted_chars /
// readback_chars）を足した。**合計 23 キー。欠損は null で必ず出す**。
//
// 収集側（MetricsSession）は AppKit と時刻に触るので Vox に置き、直列化だけここに置く。

import Foundation

public struct MetricsRecord: Encodable, Sendable {
  public static let schemaVersion = 5
  /// 契約の検証用。CodingKeys の数と一致する。
  public static let keyCount = 23

  public let toggleOnMilliseconds: Double?
  public let analyzerStartMilliseconds: Double?
  public let speechOnsetMilliseconds: Double?
  public let firstResultMilliseconds: Double?
  public let toggleOffMilliseconds: Double?
  public let finalizedMilliseconds: Double?
  public let pastePostedMilliseconds: Double?
  public let pasteReceivedMilliseconds: Double?
  public let axisAMilliseconds: Double?
  public let firstTokenMilliseconds: Double?
  public let finalTextLength: Int?
  public let targetApp: String?
  /// 失敗の理由。`input_target_unknown` / `injection_cancelled` / `modifier_release_timeout` /
  /// `input_target_changed_process` / `input_target_changed_focus` /
  /// `input_target_changed_focus_unreadable` / `paste_receipt_timeout` / `clipboard_changed`。
  /// 意味は開発手順の表を参照。
  public let error: String?
  public let targetActivateMilliseconds: Double?
  public let fillerRemovedCount: Int?
  public let typedCharacters: Int?
  public let modifierWaitMilliseconds: Double?
  public let paletteOpenedCount: Int?
  /// T22。パレットを開いてから閉じるまでの時間（給餌は止めないので再開の所要は無くなった）。
  public let paletteOpenMilliseconds: Double?
  public let paletteTargetSource: String?
  /// T19。pasteboard に置いた確定テキストの文字数。
  public let pastedCharacters: Int?
  /// T19。受領証の直後に自分で読み返した文字数。pasted と食い違ったら欠落を疑う。
  public let readbackCharacters: Int?

  public init(
    toggleOnMilliseconds: Double?,
    analyzerStartMilliseconds: Double?,
    speechOnsetMilliseconds: Double?,
    firstResultMilliseconds: Double?,
    toggleOffMilliseconds: Double?,
    finalizedMilliseconds: Double?,
    pastePostedMilliseconds: Double?,
    pasteReceivedMilliseconds: Double?,
    axisAMilliseconds: Double?,
    firstTokenMilliseconds: Double?,
    finalTextLength: Int?,
    targetApp: String?,
    error: String?,
    targetActivateMilliseconds: Double?,
    fillerRemovedCount: Int?,
    typedCharacters: Int?,
    modifierWaitMilliseconds: Double?,
    paletteOpenedCount: Int?,
    paletteOpenMilliseconds: Double?,
    paletteTargetSource: String?,
    pastedCharacters: Int?,
    readbackCharacters: Int?
  ) {
    self.toggleOnMilliseconds = toggleOnMilliseconds
    self.analyzerStartMilliseconds = analyzerStartMilliseconds
    self.speechOnsetMilliseconds = speechOnsetMilliseconds
    self.firstResultMilliseconds = firstResultMilliseconds
    self.toggleOffMilliseconds = toggleOffMilliseconds
    self.finalizedMilliseconds = finalizedMilliseconds
    self.pastePostedMilliseconds = pastePostedMilliseconds
    self.pasteReceivedMilliseconds = pasteReceivedMilliseconds
    self.axisAMilliseconds = axisAMilliseconds
    // T15。発話開始の検出が結果より遅れると差が負になる。負の初出遅延は無効なので落とす。
    self.firstTokenMilliseconds = firstTokenMilliseconds.flatMap { $0 < 0 ? nil : $0 }
    self.finalTextLength = finalTextLength
    self.targetApp = targetApp
    self.error = error
    self.targetActivateMilliseconds = targetActivateMilliseconds
    self.fillerRemovedCount = fillerRemovedCount
    self.typedCharacters = typedCharacters
    self.modifierWaitMilliseconds = modifierWaitMilliseconds
    self.paletteOpenedCount = paletteOpenedCount
    self.paletteOpenMilliseconds = paletteOpenMilliseconds
    self.paletteTargetSource = paletteTargetSource
    self.pastedCharacters = pastedCharacters
    self.readbackCharacters = readbackCharacters
  }

  public enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case toggleOnMilliseconds = "toggle_on_ms"
    case analyzerStartMilliseconds = "analyzer_start_ms"
    case speechOnsetMilliseconds = "speech_onset_ms"
    case firstResultMilliseconds = "first_result_ms"
    case toggleOffMilliseconds = "toggle_off_ms"
    case finalizedMilliseconds = "finalized_ms"
    case pastePostedMilliseconds = "paste_posted_ms"
    case pasteReceivedMilliseconds = "paste_received_ms"
    case axisAMilliseconds = "axis_a_ms"
    case firstTokenMilliseconds = "first_token_ms"
    case finalTextLength = "final_text_length"
    case targetApp = "target_app"
    case error
    case targetActivateMilliseconds = "target_activate_ms"
    case fillerRemovedCount = "filler_removed_count"
    case typedCharacters = "typed_chars"
    case modifierWaitMilliseconds = "modifier_wait_ms"
    case paletteOpenedCount = "palette_opened_count"
    case paletteOpenMilliseconds = "palette_open_ms"
    case paletteTargetSource = "palette_target_source"
    case pastedCharacters = "pasted_chars"
    case readbackCharacters = "readback_chars"
  }

  /// 合成された `encode` は Optional を `encodeIfPresent` で書き、nil のキーを落とす。
  /// 欠損キーを出さないために明示的に書く。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encodeAlways(toggleOnMilliseconds, forKey: .toggleOnMilliseconds)
    try container.encodeAlways(analyzerStartMilliseconds, forKey: .analyzerStartMilliseconds)
    try container.encodeAlways(speechOnsetMilliseconds, forKey: .speechOnsetMilliseconds)
    try container.encodeAlways(firstResultMilliseconds, forKey: .firstResultMilliseconds)
    try container.encodeAlways(toggleOffMilliseconds, forKey: .toggleOffMilliseconds)
    try container.encodeAlways(finalizedMilliseconds, forKey: .finalizedMilliseconds)
    try container.encodeAlways(pastePostedMilliseconds, forKey: .pastePostedMilliseconds)
    try container.encodeAlways(pasteReceivedMilliseconds, forKey: .pasteReceivedMilliseconds)
    try container.encodeAlways(axisAMilliseconds, forKey: .axisAMilliseconds)
    try container.encodeAlways(firstTokenMilliseconds, forKey: .firstTokenMilliseconds)
    try container.encodeAlways(finalTextLength, forKey: .finalTextLength)
    try container.encodeAlways(targetApp, forKey: .targetApp)
    try container.encodeAlways(error, forKey: .error)
    try container.encodeAlways(targetActivateMilliseconds, forKey: .targetActivateMilliseconds)
    try container.encodeAlways(fillerRemovedCount, forKey: .fillerRemovedCount)
    try container.encodeAlways(typedCharacters, forKey: .typedCharacters)
    try container.encodeAlways(modifierWaitMilliseconds, forKey: .modifierWaitMilliseconds)
    try container.encodeAlways(paletteOpenedCount, forKey: .paletteOpenedCount)
    try container.encodeAlways(paletteOpenMilliseconds, forKey: .paletteOpenMilliseconds)
    try container.encodeAlways(paletteTargetSource, forKey: .paletteTargetSource)
    try container.encodeAlways(pastedCharacters, forKey: .pastedCharacters)
    try container.encodeAlways(readbackCharacters, forKey: .readbackCharacters)
  }
}

extension KeyedEncodingContainer {
  /// nil でも `null` を書く（欠損キーを作らない）。
  mutating func encodeAlways<T: Encodable>(_ value: T?, forKey key: Key) throws {
    if let value {
      try encode(value, forKey: key)
    } else {
      try encodeNil(forKey: key)
    }
  }
}

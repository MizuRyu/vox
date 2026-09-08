// 軸 A（発話終了 → 挿入完了）の計測。1 入力 = 1 行の収集側。
// 直列化とスキーマ（schema_version 5 / 23 キー）は VoxCore.MetricsRecord が持つ。

import Foundation
import OSLog
import VoxCore

func voxPrimeClock() {
  _ = VoxMonotonicClock.nowSeconds()
}

func voxNowMilliseconds() -> Double {
  VoxMonotonicClock.nowMilliseconds()
}
/// 1 入力 = 1 行。トグル ON から挿入完了までに集める値を溜める箱。
@MainActor
struct MetricsSession {
  var toggleOnMilliseconds: Double
  var analyzerStartMilliseconds: Double?
  var speechOnsetMilliseconds: Double?
  var firstResultMilliseconds: Double?
  var toggleOffMilliseconds: Double?
  var finalizedMilliseconds: Double?
  var pastePostedMilliseconds: Double?
  var pasteReceivedMilliseconds: Double?
  var finalTextLength: Int?
  var targetApp: String?
  var error: String?
  /// R16。挿入先を前面に戻すのにかかった時間。activate を呼ばなかったら nil。
  var targetActivateMilliseconds: Double?
  /// R18。committed から除去したフィラーの語数。
  var fillerRemovedCount = 0
  /// R14。この入力でユーザーが打った文字数。
  var typedCharacters = 0
  /// T19。pasteboard に置いた文字数と、受領証の直後に読み返した文字数。
  var pastedCharacters: Int?
  var readbackCharacters: Int?
  /// 合成 Cmd+V の前に修飾キーの解放を待った時間。待たなければ 0。
  var modifierWaitMilliseconds = 0.0
  /// M3。この入力でパレットを開いた回数。
  var paletteOpenedCount = 0
  /// T22。パレットを開いてから閉じるまでの時間。複数回開いたときは最後の 1 回。
  var paletteOpenMilliseconds: Double?
  /// M3。検索対象をどのアダプタで決めたか（orca / terminal / fallback）。特定できなければ nil。
  var paletteTargetSource: String?

  init(toggleOnMilliseconds: Double) {
    self.toggleOnMilliseconds = toggleOnMilliseconds
    // 前の回の長さを持ち越さない。
  }

  var record: MetricsRecord {
    let axisA: Double? = {
      guard let received = pasteReceivedMilliseconds, let off = toggleOffMilliseconds else {
        return nil
      }
      return received - off
    }()
    let firstToken: Double? = {
      guard let first = firstResultMilliseconds, let onset = speechOnsetMilliseconds else {
        return nil
      }
      return first - onset
    }()
    return MetricsRecord(
      toggleOnMilliseconds: toggleOnMilliseconds,
      analyzerStartMilliseconds: analyzerStartMilliseconds,
      speechOnsetMilliseconds: speechOnsetMilliseconds,
      firstResultMilliseconds: firstResultMilliseconds,
      toggleOffMilliseconds: toggleOffMilliseconds,
      finalizedMilliseconds: finalizedMilliseconds,
      pastePostedMilliseconds: pastePostedMilliseconds,
      pasteReceivedMilliseconds: pasteReceivedMilliseconds,
      axisAMilliseconds: axisA,
      firstTokenMilliseconds: firstToken,
      finalTextLength: finalTextLength,
      targetApp: targetApp,
      error: error,
      targetActivateMilliseconds: targetActivateMilliseconds,
      fillerRemovedCount: fillerRemovedCount,
      typedCharacters: typedCharacters,
      modifierWaitMilliseconds: modifierWaitMilliseconds,
      paletteOpenedCount: paletteOpenedCount,
      paletteOpenMilliseconds: paletteOpenMilliseconds,
      paletteTargetSource: paletteTargetSource,
      pastedCharacters: pastedCharacters,
      readbackCharacters: readbackCharacters
    )
  }
}

/// JSONL への 1 行追記。書き込み失敗は stderr に出すだけで、入力操作は止めない。
final class MetricsWriter {
  private let url: URL
  private let encoder: JSONEncoder

  init(path: String) {
    self.url = URL(fileURLWithPath: path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
  }

  var displayPath: String { url.path }

  func append(_ record: MetricsRecord) {
    do {
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let line = String(data: try encoder.encode(record), encoding: .utf8) else {
        voxLog("metrics_error encoding_failed")
        return
      }
      let data = Data((line + "\n").utf8)
      try PrivateFileIO.append(data, to: url)
      voxLog("metrics_appended \(line)")
    } catch {
      voxLog("metrics_error \(String(describing: error))")
    }
  }
}

/// ログはすべて stderr。tap コールバック（オーディオスレッド）からも呼ぶので排他する。
private let voxLogLock = NSLock()

func voxLog(_ line: String) {
  voxLogLock.lock()
  defer { voxLogLock.unlock() }
  voxWriteLog(line, to: FileHandle.standardError)
}

/// why: ファイルパスは本文と同じく私的（作業場所と選んだファイル名が残る）。
/// 診断ログに出すのは `--log-text` の回だけにする。
func voxLoggable(path: String) -> String {
  VoxConfig.logFinalText ? path : "-"
}

/// why: 書き込みは best-effort。stderr がログファイルに向いている bundled 起動では
/// ディスク満杯で失敗しうるが、旧 API の `write(_:)` は捕捉できない例外で本体を落とす。
/// 失敗は本文を出さずに os_log へ 1 行だけ残す（同じ書き込み先には知らせられない）。
func voxWriteLog(_ line: String, to handle: FileHandle) {
  voxWrite(Data((line + "\n").utf8), to: handle)
}

/// 改行まで自分で組み立てる書き込み（利用者向けのメッセージ）。失敗の扱いは同じ。
func voxWrite(_ data: Data, to handle: FileHandle) {
  do {
    try handle.write(contentsOf: data)
  } catch {
    Logger(subsystem: "local.vox.app", category: "log").error("log_write_failed")
  }
}

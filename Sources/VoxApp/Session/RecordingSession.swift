// 録音キー ON から close までの 1 回分。VoxController はこれを高々 1 つ持ち、begin で作って close で捨てる。
// 設定と挿入先はここで固定する（録音中に設定を変えても、この回には効かない）。

import AppKit
import Foundation
import VoxCore

@MainActor
final class RecordingSession {
  /// 1 行書いたら捨てる。捨てた後の経路は行を足さない（破棄とマイク不許可も同じ扱い）。
  var metrics: MetricsSession?
  let autoEnterEnabled: Bool
  let autoEnterUnverified: Bool
  let voiceProcessingEnabled: Bool
  let microphoneInput: MicrophoneInput
  /// ADR-019。トグル ON 時に読んだ辞書。録音中にファイルを変えてもこの回には効かない。
  let dictionary: DictionaryTable
  /// R16。トグル ON 時の前面アプリ。確定までここに固定する。
  let target: NSRunningApplication?
  let injectionTarget: CapturedInjectionTarget?
  /// R17 の `raw_text` 用。フィラー除去前の committed と tentative。
  var rawCommitted = ""
  var rawTentative = ""
  var autoEnterCancelled = false
  var cancelRequested = false
  /// 準備中に入力デバイスが変わった。開始処理が戻ったところで諦める。
  var captureInterrupted = false
  /// ADR-020。この録音の無音での区切り。パレットで締めた時刻も入れる。
  var pauseCommit = PauseCommitPolicy()
  /// ADR-022 / ADR-023。ほかのアプリから声だけで使う指定付きで始めた回だけ持つ。
  let handsFree: HandsFreePolicy?
  /// マイクが実際に聞き始めた時刻。声だけで使う録音の「話さない時間」の起点。
  var listeningSince: Double?
  /// この録音で一度でも本文が入った、または変換中だったか。消した後も声だけの規則でやめない。
  var hadInput = false
  /// 区切りの締めが走り始めた時刻。無音での確定がそれを待つ上限の起点。
  var finalizePendingSince: Double?
  /// この回の非同期処理（開始・確定・破棄）。次の段階に進むたびに置き換わる。
  var task: Task<Void, Never>?

  init(
    toggleOnMilliseconds: Double, settings: SettingsCoordinator, dictionary: DictionaryTable,
    target: NSRunningApplication?, handsFree: HandsFreePolicy? = nil
  ) {
    self.handsFree = handsFree
    autoEnterEnabled = settings.autoEnterEnabled
    autoEnterUnverified = settings.autoEnterUnverified
    voiceProcessingEnabled = settings.voiceProcessingEnabled
    microphoneInput = settings.microphoneInput
    self.dictionary = dictionary
    self.target = target
    injectionTarget = target.map {
      Injector.captureTarget(
        processID: $0.processIdentifier,
        includeWindow: settings.autoEnterEnabled && settings.autoEnterUnverified)
    }
    var metrics = MetricsSession(toggleOnMilliseconds: toggleOnMilliseconds)
    metrics.targetApp = target?.bundleIdentifier
    self.metrics = metrics
  }
}

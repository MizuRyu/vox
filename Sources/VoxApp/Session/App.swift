// 常駐本体。トグルキーで HUD + 速報レーンを開閉し、確定時に挿入して計測と履歴を 1 行ずつ書く。
//
// M2 で足したもの:
//   R16 挿入先はトグル ON 時の前面アプリに固定し、確定時に activate を確認してから Cmd+V
//   R17 確定テキストは挿入の成否に関わらず履歴に残す
//   R18 final を committed に追記する前にフィラーを除去する（HUD 表示と挿入テキストが一致する）
//   R14 テキスト入力の割り込み。HUD 表示中は HUD が key window で、打った文字が caret 位置に入る
//
// M3 で足したもの:
//   R3/R4 コマンドパレット。⌃P でファイルを選び、Enter で committed にパスを差し込む
//   T13 HUD に打った `@` も同じ経路でパレットを開く。パスは `@` を打った caret 位置に入る
//   T22 パレット表示中も音声供給は止めない。開いた時点の淡色だけ締め、差し込みは閉じる時点の末尾

import AppKit
import AVFoundation
import Foundation
import VoxCore

@MainActor
final class VoxController {
  private typealias State = SettingsPresentationState.Phase

  private let hud = HudPanel()
  private let palette: PaletteCoordinator
  private let lane = SpeechLane()
  private let injector = Injector()
  private let hotkeys = HotkeyMonitor()
  private let metrics: MetricsWriter
  private let history: HistoryWriter
  private let settings: SettingsCoordinator

  var onResidentPhaseChange: ((ResidentPhase, String?) -> Void)?

  private var state = State.idle {
    didSet {
      settings.transition(to: state)
      onResidentPhaseChange?(residentPhase, nil)
    }
  }
  /// 進行中の 1 録音分。@testable な検査が close 後の後始末を見る。
  private(set) var recording: RecordingSession?
  private var levelTask: Task<Void, Never>?
  private var isShuttingDown = false
  private var menuTargetApplication: NSRunningApplication?

  /// 未実装 sigil の表示を戻すタスク。HUD の表示都合なので録音 1 回分には含めない。
  private var sigilNoticeTask: Task<Void, Never>?

  init(metrics: MetricsWriter, history: HistoryWriter, settings: SettingsController) {
    self.metrics = metrics
    self.history = history
    let palette = PaletteCoordinator(hud: hud)
    self.palette = palette
    self.settings = SettingsCoordinator(
      controller: settings, hud: hud, hotkeys: hotkeys, palette: palette)
  }

  func start(enableHotkeys: Bool = true) throws {
    settings.connect()

    lane.onTextUpdate = { [weak self] committed, tentative in
      self?.acceptText(committed: committed, tentative: tentative)
    }
    lane.onFirstResult = { [weak self] at in
      guard let self else { return }
      recording?.metrics?.firstResultMilliseconds = at
      hud.model.status = "録音中"
    }
    lane.onAssetInstallStarted = { [weak self] in
      self?.hud.model.status = "モデルを準備中"
    }
    lane.onCaptureInterrupted = { [weak self] transport in
      self?.captureInterrupted(transport: transport)
    }
    // T15。IME の変換中の esc は変換のキャンセル、⌃P は変換候補の操作。tap で飲まない。
    hotkeys.wantsEscape = { [weak self] in
      guard let self, !hud.model.isComposing else { return false }
      return state == .starting || state == .recording
        || (state == .finishing && recording?.autoEnterEnabled == true)
    }
    hotkeys.wantsPalette = { [weak self] in
      guard let self, !hud.model.isComposing else { return false }
      return state == .recording
    }
    hotkeys.onEvent = { [weak self] event in
      self?.handle(event)
    }
    hotkeys.toggleChord = VoxConfig.toggleChord
    hotkeys.paletteChord = VoxConfig.paletteChord
    palette.finalizeSegment = { [weak self] in
      guard let self else { return }
      await lane.finalizeSegment()
    }
    palette.targetBundleIdentifier = { [weak self] in
      self?.recording?.target?.bundleIdentifier
    }
    palette.onMetric = { [weak self] metric in self?.record(metric) }
    // T13。HUD のテキスト領域に打った sigil。shouldChangeTextIn からここに来る。
    // 開くのは 1 hop 遅らせる（テキストビューの変更処理の中でパネルを key にしない）。
    hud.model.sigilTriggerEnabled = VoxConfig.sigilTriggerEnabled
    hud.model.onSigil = { [weak self] sigil, caret in
      Task { @MainActor in
        self?.openPalette(sigil: sigil, atMilliseconds: voxNowMilliseconds(), typedAt: caret)
      }
    }
    if enableHotkeys { try hotkeys.start() }
    settings.listen()
  }

  func enableHotkeys() throws {
    guard !isShuttingDown else { return }
    try hotkeys.start()
  }

  func disableHotkeysWhenIdle() {
    guard state == .idle else { return }
    hotkeys.stop()
  }

  var residentPhase: ResidentPhase {
    switch state {
    case .idle: .idle
    case .starting: .starting
    case .recording: .recording
    case .finishing: .finishing
    }
  }

  func captureMenuTarget() {
    let candidate = NSWorkspace.shared.frontmostApplication
    menuTargetApplication = ResidentTargetPolicy.isEligible(
      bundleIdentifier: candidate?.bundleIdentifier) ? candidate : nil
  }

  @discardableResult
  func performMenuPrimaryAction() -> Bool {
    switch state {
    case .idle:
      guard let target = menuTargetApplication else { return false }
      begin(toggleOnMilliseconds: voxNowMilliseconds(), targetOverride: target)
      self.menuTargetApplication = nil
      return true
    case .recording:
      finish(toggleOffMilliseconds: voxNowMilliseconds())
      return true
    case .starting, .finishing:
      return false
    }
  }

  func shutdown() async {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    recording?.task?.cancel()
    palette.cancelPendingWork()
    sigilNoticeTask?.cancel()
    hotkeys.stop()
    await lane.abort()
    close()
  }

  // MARK: キー

  private func handle(_ event: HotkeyEvent) {
    switch event {
    case .toggle(let at):
      if palette.isOpen {
        // パレットを出したままトグルされたら、挿入せず閉じてから通常の確定に進む。
        palette.close(insert: nil, fileNameOnly: false)
      }
      switch state {
      case .idle:
        begin(toggleOnMilliseconds: at, targetOverride: nil)
      case .recording:
        finish(toggleOffMilliseconds: at)
      case .starting:
        // 準備中の 2 度押しは破棄として扱う（マイクが開いたままにならないように）。
        voxLog("toggle ignored state=starting")
      case .finishing:
        voxLog("toggle ignored state=finishing")
      }
    case .palette(let at):
      openPalette(sigil: .file, atMilliseconds: at, typedAt: nil)
    case .escape:
      if palette.isOpen {
        // パレット表示中の esc は「挿入せず閉じる」。録音は止めない。
        palette.close(insert: nil, fileNameOnly: false)
        return
      }
      switch state {
      case .starting:
        recording?.cancelRequested = true
        voxLog("escape queued state=starting")
      case .recording:
        // esc は破棄 1 回のみ（R14 改訂で「編集モードを抜ける」は廃止）。
        discard()
      case .finishing:
        recording?.autoEnterCancelled = true
      case .idle:
        break
      }
    }
  }

  // MARK: M3 コマンドパレット

  private func openPalette(sigil: PaletteSigil, atMilliseconds: Double, typedAt: Int?) {
    guard state == .recording, !palette.isOpen else { return }
    guard sigil.isImplemented else {
      showUnimplementedSigil(sigil)
      return
    }
    palette.open(atMilliseconds: atMilliseconds, typedAt: typedAt)
  }

  /// `#` `!` `~`。M3 では候補を出せないので、パレットを開かずに状態表示だけ差し替える。
  private func showUnimplementedSigil(_ sigil: PaletteSigil) {
    voxLog("sigil_unimplemented \(sigil.rawValue)")
    hud.model.status = "\(sigil.rawValue) \(sigil.label) は未実装です"
    sigilNoticeTask?.cancel()
    sigilNoticeTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1200))
      guard !Task.isCancelled, state == .recording, !palette.isOpen else { return }
      hud.model.status = "録音中"
    }
  }

  private func record(_ metric: PaletteCoordinator.Metric) {
    switch metric {
    case .opened: recording?.metrics?.paletteOpenedCount += 1
    case .targetResolved(let source): recording?.metrics?.paletteTargetSource = source
    case .closed(let openMilliseconds):
      recording?.metrics?.paletteOpenMilliseconds = openMilliseconds
    }
  }

  // MARK: R18 テキストの受け取り

  /// 速報レーンは raw な committed / tentative を全文で返す。committed は追記専用なので差分だけ取り、
  /// **committed に足す前に**フィラーを除去する（ADR-012。tentative には掛けない）。
  /// 編集モード中でもここは追記なので、ユーザーが打った内容を壊さない。
  private func acceptText(committed: String, tentative: String) {
    guard let recording else { return }
    if let delta = TranscriptDelta.appended(
      previous: recording.rawCommitted, current: committed) {
      if !delta.isEmpty {
        // T21。`head` の末尾に足すだけ。打った文字（tail）は動かさない。
        hud.model.commitFinal(clean(delta, into: recording))
      }
    } else {
      // 追記専用の契約が破れた場合（想定外）。全文を作り直す。
      voxLog(
        "committed_not_append_only length=\(committed.count) "
          + "previous=\(recording.rawCommitted.count)")
      // 作り直した回は除去数も数え直す（差分ぶんを足したままにしない）。
      recording.metrics?.fillerRemovedCount = 0
      hud.model.head = clean(committed, into: recording)
    }
    recording.rawCommitted = committed
    recording.rawTentative = tentative
    // T21。淡色が空 → 非空になる回にここで `tail` が `head` に合流する（時間順）。
    hud.model.applyTentative(tentative)
    // T18。展開中は伸びた本文に高さを合わせる。
    hud.refreshExpandedHeight()
    if ProcessInfo.processInfo.environment["VOX_HUD_DEBUG"] == "1" {
      voxLog(
        "hud_model head=\(hud.model.head.count) tentative=\(hud.model.tentative.count) tail=\(hud.model.tail.count) "
          + "visible=\(hud.isVisible)")
    }
  }

  private func clean(_ text: String, into recording: RecordingSession) -> String {
    let removal = FillerPass.remove(from: text, enabled: VoxConfig.fillerRemovalEnabled)
    recording.metrics?.fillerRemovedCount += removal.removedCount
    return removal.text
  }

  // MARK: トグル ON

  private func begin(
    toggleOnMilliseconds: Double, targetOverride: NSRunningApplication?
  ) {
    guard !isShuttingDown else { return }
    settings.reload()
    settings.beginSession()
    settings.hide()
    state = .starting
    // R16: 挿入先はここで固定する。編集モードや将来のパレットで HUD が key になっても動かさない。
    let frontmost = NSWorkspace.shared.frontmostApplication
    let target = targetOverride ?? (ResidentTargetPolicy.isEligible(
      bundleIdentifier: frontmost?.bundleIdentifier) ? frontmost : nil)
    let recording = RecordingSession(
      toggleOnMilliseconds: toggleOnMilliseconds, settings: settings, target: target)
    self.recording = recording
    hud.reset(status: "準備中")
    hud.show()
    voxLog("target_app fixed=\(target?.bundleIdentifier ?? "-")")

    recording.task = Task { @MainActor in
      do {
        guard await ensureMicrophoneAccess() else {
          guard proceed(recording) else { close(); return }
          recording.metrics = nil
          hud.model.notice = "マイクの権限が必要です。システム設定でVoxを許可してください"
          closeAfter(milliseconds: 2500, residentPhaseAfterClose: .permissionRequired)
          return
        }
        guard proceed(recording) else { close(); return }
        let analyzerStart = try await lane.start(
          voiceProcessingEnabled: recording.voiceProcessingEnabled)
        recording.metrics?.analyzerStartMilliseconds = analyzerStart
        if recording.captureInterrupted {
          await lane.abort()
          guard proceed(recording) else { close(); return }
          recording.metrics = nil
          hud.model.notice = "入力デバイスが変わったため、録音を開始できませんでした"
          closeAfter(milliseconds: 2500)
          return
        }
        if recording.cancelRequested || !proceed(recording) {
          await lane.abort()
          close()
          return
        }
        state = .recording
        hud.model.status = "録音中"
        hud.model.isRecording = true
        startLevelUpdates()
      } catch {
        await lane.abort()
        guard proceed(recording) else { close(); return }
        let message = String(describing: error)
        voxLog("start_error \(message)")
        onResidentPhaseChange?(.error, "録音を開始できませんでした")
        recording.metrics?.error = "start_failed"
        flushMetrics(recording)
        // 起動に失敗した回は「1 確定」ではないので履歴には書かない。
        hud.model.notice = "録音を開始できませんでした: \(message)"
        closeAfter(milliseconds: 2500, residentPhaseAfterClose: .error)
      }
    }
  }

  // MARK: esc（破棄）

  private func discard() {
    guard let recording else { return }
    state = .finishing
    hud.model.isRecording = false
    stopLevelUpdates()
    voxLog("discarded")
    recording.task = Task { @MainActor in
      await lane.abort()
      // 破棄は「1 回の入力」ではないので JSONL にも履歴にも書かない（軸 A の母数を汚さない）。
      recording.metrics = nil
      close()
    }
  }

  // MARK: 後片付け

  /// 中断されていれば false。この回の非同期処理は、ここが false を返したら何もせずに畳む。
  private func proceed(_ session: RecordingSession) -> Bool {
    !Task.isCancelled && !isShuttingDown && recording === session
  }

  private func flushMetrics(_ recording: RecordingSession) {
    guard var metricsSession = recording.metrics else { return }
    metricsSession.speechOnsetMilliseconds = lane.levels.onsetMilliseconds
    metrics.append(metricsSession.record)
    recording.metrics = nil
  }

  /// R17。`finish` の全経路で 1 行書く。挿入の成否は行の中身で表す。
  private func appendHistory(
    _ recording: RecordingSession,
    rawText: String, insertedText: String?, inserted: Bool, error: String?, edited: Bool
  ) {
    history.append(
      HistoryRecord(
        at: HistoryStore.timestamp(Date()),
        rawText: rawText,
        insertedText: insertedText,
        targetApp: recording.target?.bundleIdentifier,
        inserted: inserted,
        error: error,
        edited: edited))
  }

  private func close() {
    settings.hide()
    settings.endSession()
    stopLevelUpdates()
    palette.reset()
    sigilNoticeTask?.cancel()
    sigilNoticeTask = nil
    hud.model.isRecording = false
    hud.hide()
    recording = nil
    state = .idle
  }

  private func closeAfter(
    milliseconds: Int, residentPhaseAfterClose: ResidentPhase? = nil
  ) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(milliseconds))
      close()
      if let residentPhaseAfterClose {
        onResidentPhaseChange?(residentPhaseAfterClose, nil)
      }
    }
  }

  private func startLevelUpdates() {
    stopLevelUpdates()
    levelTask = Task { @MainActor in
      while !Task.isCancelled {
        hud.model.level = lane.levels.level
        try? await Task.sleep(for: .milliseconds(66))
      }
    }
  }

  private func stopLevelUpdates() {
    levelTask?.cancel()
    levelTask = nil
    hud.model.level = 0
  }
}

// MARK: トグル OFF（確定して挿入）

extension VoxController {

  private func finish(toggleOffMilliseconds: Double) {
    guard let recording, proceed(recording) else { return }
    state = .finishing
    hud.model.isRecording = false
    stopLevelUpdates()
    recording.metrics?.toggleOffMilliseconds = toggleOffMilliseconds
    hud.model.status = "確定中"

    recording.task = Task { @MainActor in
      do {
        // パレットを出したまま確定された場合。締めるタスクが走り切ってから finalize する。
        await palette.awaitPendingFinalize()
        let (finalizedMilliseconds, rawText) = try await lane.finalizeText()
        guard proceed(recording) else { close(); return }
        recording.metrics?.finalizedMilliseconds = finalizedMilliseconds

        // HUD は key window なので、まず key を返してから挿入経路に入る（R14 → R16）。
        hud.resignKeyForInsertion()
        let typed = hud.model.typedCharacters
        recording.metrics?.typedCharacters = typed

        // 挿入するのは HUD に見えているもの。フィラー除去も編集も反映済み（WYSIWYG）。
        // T21。並びは head + tentative + tail（打った分は淡色の後ろ）。
        let text = hud.model.transcript.text
        recording.metrics?.finalTextLength = text.count
        if VoxConfig.logFinalText {
          voxLog("final_text \(text.replacingOccurrences(of: "\n", with: "\\n"))")
        }

        guard !text.isEmpty else {
          voxLog("final_text empty")
          recording.metrics?.error = "empty_text"
          flushMetrics(recording)
          appendHistory(
            recording,
            rawText: rawText, insertedText: nil, inserted: false, error: "empty_text",
            edited: typed > 0)
          close()
          return
        }

        await insertFinalText(text, recording: recording, rawText: rawText, typed: typed)
      } catch {
        await lane.abort()
        guard proceed(recording) else { close(); return }
        let message = String(describing: error)
        voxLog("finalize_error \(message)")
        onResidentPhaseChange?(.error, "確定できませんでした")
        recording.metrics?.error = "finalize_failed"
        let raw = recording.rawCommitted + recording.rawTentative
        // 締めに失敗しても見えている本文は消さない。finalized_ms だけが取れない（nil のまま）。
        guard
          case .insert(let text) = FinalizeFallback.decide(
            head: hud.model.head, tentative: hud.model.tentative, tail: hud.model.tail)
        else {
          flushMetrics(recording)
          appendHistory(
            recording,
            rawText: raw, insertedText: nil, inserted: false,
            error: "finalize_failed", edited: hud.model.typedCharacters > 0)
          hud.model.notice = "確定できませんでした。\(message)"
          closeAfter(milliseconds: 2500, residentPhaseAfterClose: .error)
          return
        }
        await insertVisibleTranscript(
          recording, text: text, rawText: raw,
          notice: "認識を締められなかったため、表示中の本文をそのまま貼り付けます")
      }
    }
  }

  /// 締めを通さずに、表示中の本文を挿入経路へ渡す。締めの失敗と入力デバイスの変化で共用。
  private func insertVisibleTranscript(
    _ recording: RecordingSession, text: String, rawText: String, notice: String
  ) async {
    hud.resignKeyForInsertion()
    let typed = hud.model.typedCharacters
    recording.metrics?.typedCharacters = typed
    recording.metrics?.finalTextLength = text.count
    hud.model.notice = notice
    await insertFinalText(text, recording: recording, rawText: rawText, typed: typed)
  }

  private func insertFinalText(
    _ text: String, recording: RecordingSession, rawText: String, typed: Int
  ) async {
    // R16: 挿入先が前面でなければ戻す。戻せなければ挿入しない。
    let activation = await activateTargetIfNeeded(recording.target)
    recording.metrics?.targetActivateMilliseconds = activation.milliseconds
    if let activationError = activation.error {
      injector.copyToClipboard(text: text)
      recording.metrics?.error = activationError
      flushMetrics(recording)
      appendHistory(
        recording,
        rawText: rawText, insertedText: nil, inserted: false, error: activationError,
        edited: typed > 0)
      hud.model.notice = "貼り付け先を前面に戻せませんでした。本文はクリップボードにあります"
      closeAfter(milliseconds: 2500)
      return
    }

    guard let injectionTarget = recording.injectionTarget else {
      recording.metrics?.error = "input_target_unknown"
      flushMetrics(recording)
      appendHistory(
        recording,
        rawText: rawText, insertedText: nil, inserted: false,
        error: "input_target_unknown", edited: typed > 0)
      hud.model.notice = "貼り付け先を確認できませんでした"
      closeAfter(milliseconds: 2500)
      return
    }
    let outcome = await injector.insert(text: text, target: injectionTarget,
      autoEnterEnabled: recording.autoEnterEnabled, autoEnterUnverified: recording.autoEnterUnverified,
      cancelAutoEnter: { recording.autoEnterCancelled || Task.isCancelled })
    recording.metrics?.pastePostedMilliseconds = outcome.pastePostedMilliseconds
    recording.metrics?.pasteReceivedMilliseconds = outcome.pasteReceivedMilliseconds
    recording.metrics?.modifierWaitMilliseconds = outcome.modifierWaitMilliseconds
    // T19。置いた文字数と、受領証の直後に自分で読み返した文字数。
    // readback が全長なら「消費者が読んだ時点の pasteboard には全量が載っていた」と言える。
    recording.metrics?.pastedCharacters = outcome.pastedCharacters
    recording.metrics?.readbackCharacters = outcome.readbackCharacters
    // 締めに失敗して退避してきた回は、挿入が成功しても finalize_failed を計測に残す。
    recording.metrics?.error = outcome.error ?? recording.metrics?.error
    flushMetrics(recording)
    // クリップボードに載せて Cmd+V まで送った回は inserted_text を残す。
    // 受領証が来なくてもテキストはクリップボードにあり、行方不明にはしない（R17）。
    appendHistory(
      recording,
      rawText: rawText, insertedText: text,
      inserted: outcome.pasteVerified, error: outcome.error,
      edited: typed > 0)

    if outcome.pasteReceivedMilliseconds == nil {
      let head = outcome.pastePosted ? "貼り付けを確認できませんでした" : "貼り付けませんでした"
      hud.model.notice = outcome.clipboardContainsText
        ? "\(head)。本文はクリップボードにあります" : head
      closeAfter(milliseconds: 2500)
    } else if let notice = outcome.autoEnterResult.notice {
      hud.model.notice = notice
      closeAfter(milliseconds: 2500)
    } else {
      close()
    }
  }

  /// R16。前面が `targetApp` でなければ activate し、実際に前面になるまで最大 500ms 待つ。
  /// 前面が変わっていない通常経路では activate を呼ばない（軸 A に上乗せしない）。
  private func activateTargetIfNeeded(
    _ target: NSRunningApplication?
  ) async -> (milliseconds: Double?, error: String?) {
    let workspace = NSWorkspace.shared
    guard let target,
      ActivationPolicy.needsActivation(
        frontmostProcessID: workspace.frontmostApplication?.processIdentifier,
        targetProcessID: target.processIdentifier)
    else { return (nil, nil) }

    let start = voxNowMilliseconds()
    target.activate()
    let deadline = start + ActivationPolicy.timeoutMilliseconds
    var becameFrontmost = false
    while voxNowMilliseconds() < deadline {
      try? await Task.sleep(
        for: .milliseconds(Int(ActivationPolicy.pollIntervalMilliseconds)))
      if workspace.frontmostApplication?.processIdentifier == target.processIdentifier {
        becameFrontmost = true
        break
      }
    }
    let outcome = ActivationPolicy.outcome(
      becameFrontmost: becameFrontmost, elapsedMilliseconds: voxNowMilliseconds() - start)
    voxLog("target_activate ms=\(outcome.milliseconds ?? 0) error=\(outcome.error ?? "-")")
    return outcome
  }
}

// MARK: 入力デバイスの変化（録音の中断）

/// 録音中にデバイスが変わって engine が止まったときの分岐。
enum CaptureInterruptionOutcome: Equatable {
  /// 録音中。表示中の本文を挿入経路へ渡す。
  case insert(String)
  /// 録音中だが画面にも何も残っていない。貼り付けずに閉じる。
  case giveUp
  /// 準備中。開始を諦める。
  case abortStart
  /// 確定中と待機中は、走っている挿入を邪魔しない。
  case ignore
}

extension VoxController {
  static func captureInterruptionOutcome(
    phase: SettingsPresentationState.Phase, head: String, tentative: String, tail: String
  ) -> CaptureInterruptionOutcome {
    switch phase {
    case .recording:
      if case .insert(let text) = FinalizeFallback.decide(
        head: head, tentative: tentative, tail: tail) {
        return .insert(text)
      }
      return .giveUp
    case .starting: return .abortStart
    case .finishing, .idle: return .ignore
    }
  }

  private func captureInterrupted(transport: AudioTransport) {
    guard let recording, proceed(recording) else { return }
    let outcome = Self.captureInterruptionOutcome(
      phase: state, head: hud.model.head, tentative: hud.model.tentative, tail: hud.model.tail)
    switch outcome {
    case .insert, .giveUp:
      voxLog("audio_configuration_changed transport=\(transport.logLabel) phase=recording")
      endAfterCaptureInterruption(recording, outcome: outcome)
    case .abortStart:
      voxLog("audio_configuration_changed transport=\(transport.logLabel) phase=starting")
      recording.captureInterrupted = true
    case .ignore:
      break
    }
  }

  /// engine は既に止まっているので締めは通さず、見えている本文をそのまま貼り付けて終える。
  private func endAfterCaptureInterruption(
    _ recording: RecordingSession, outcome: CaptureInterruptionOutcome
  ) {
    state = .finishing
    hud.model.isRecording = false
    stopLevelUpdates()
    recording.metrics?.toggleOffMilliseconds = voxNowMilliseconds()

    recording.task = Task { @MainActor in
      await lane.abort()
      guard proceed(recording) else { close(); return }
      let raw = recording.rawCommitted + recording.rawTentative
      guard case .insert(let text) = outcome else {
        recording.metrics?.error = "empty_text"
        flushMetrics(recording)
        appendHistory(
          recording,
          rawText: raw, insertedText: nil, inserted: false, error: "empty_text",
          edited: hud.model.typedCharacters > 0)
        hud.model.notice = "入力デバイスが変わったため、録音を終了しました"
        closeAfter(milliseconds: 2500)
        return
      }
      await insertVisibleTranscript(
        recording, text: text, rawText: raw,
        notice: "入力デバイスが変わったため、ここまでの本文を貼り付けます")
    }
  }
}

/// マイク権限。プローブの ensureMicrophoneAccess と同じ手順。
@MainActor
func ensureMicrophoneAccess() async -> Bool {
  switch AVCaptureDevice.authorizationStatus(for: .audio) {
  case .authorized:
    return true
  case .notDetermined:
    return await AVCaptureDevice.requestAccess(for: .audio)
  default:
    return false
  }
}

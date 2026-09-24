// ADR-022。ほかのアプリから届く `vox://` の URL の解釈。

import Foundation
import Testing
import VoxCore

@Suite("Resident: 外部からの録音操作の URL")
struct ExternalCommandTests {
  private func parse(_ string: String) -> Result<ExternalCommand, ExternalCommand.ParseError> {
    guard let url = URL(string: string) else { return .failure(.malformed) }
    return ExternalCommand.parse(url)
  }

  @Test("3 つの操作を読み、指定の無い開始は既定の貼り先で無音確定なし")
  func readsTheThreeCommands() {
    #expect(parse("vox://record/start") == .success(.start(.init())), "start を読めない")
    #expect(parse("vox://record/finish") == .success(.finish), "finish を読めない")
    #expect(parse("vox://record/toggle") == .success(.toggle(.init())), "toggle を読めない")
  }

  @Test("開始は貼り先と無音での確定を受け取る")
  func startCarriesTargetAndSilence() {
    let options = ExternalCommand.StartOptions(
      targetBundleIdentifier: "com.example.terminal", finishAfterSilenceMilliseconds: 1_500)
    #expect(
      parse("vox://record/start?target=com.example.terminal&finish_after_silence_ms=1500")
        == .success(.start(options)), "開始の指定を落とした")
    #expect(
      parse("vox://record/toggle?finish_after_silence_ms=800")
        == .success(.toggle(.init(finishAfterSilenceMilliseconds: 800))), "toggle の指定を落とした")
  }

  @Test("無音の時間は 800〜10,000 の整数だけ")
  func silenceMustBeInRange() {
    for value in ["799", "10001", "-1", "1.5", "abc", "", "１５００"] {
      #expect(
        parse("vox://record/start?finish_after_silence_ms=\(value)") == .failure(.invalidSilence),
        "\(value) を受け付けた")
    }
    #expect(
      parse("vox://record/start?finish_after_silence_ms=10000")
        == .success(.start(.init(finishAfterSilenceMilliseconds: 10_000))), "上限を拒んだ")
  }

  @Test("話さなければやめるまでの時間は 3,000〜120,000 の整数だけ")
  func noSpeechMustBeInRange() {
    #expect(
      parse("vox://record/start?finish_after_silence_ms=1500&cancel_if_no_speech_ms=20000")
        == .success(.start(.init(finishAfterSilenceMilliseconds: 1_500, cancelIfNoSpeechMilliseconds: 20_000))),
      "指定を落とした")
    for value in ["2999", "120001", "abc", ""] {
      #expect(
        parse("vox://record/start?cancel_if_no_speech_ms=\(value)") == .failure(.invalidNoSpeech),
        "\(value) を受け付けた")
    }
  }

  @Test("声だけで使う指定が無ければ、録音キーと同じ録音になる")
  func handsFreeOnlyWhenAsked() {
    #expect(ExternalCommand.StartOptions().handsFree == nil, "指定が無いのに声で確定する録音になった")
    #expect(
      ExternalCommand.StartOptions(cancelIfNoSpeechMilliseconds: 3_000).handsFree
        == HandsFreePolicy(finishAfterSilenceMilliseconds: nil, cancelIfNoSpeechMilliseconds: 3_000),
      "片方だけの指定が伝わらない")
  }

  @Test("貼り先は bundle identifier の文字だけ")
  func targetMustLookLikeABundleIdentifier() {
    for value in ["", "com.example/..", "com example", "a%0Ab"] {
      #expect(
        parse("vox://record/start?target=\(value)") == .failure(.invalidTarget), "\(value) を受け付けた")
    }
  }

  @Test("知らない操作・スキーム・余分な指定は拒む")
  func rejectsEverythingElse() {
    #expect(parse("https://record/start") == .failure(.unsupportedScheme), "別のスキームを受け付けた")
    #expect(parse("vox://record/pause") == .failure(.unknownCommand), "知らない操作を受け付けた")
    #expect(parse("vox://settings/start") == .failure(.unknownCommand), "別の対象を受け付けた")
    #expect(parse("vox://record/start/now") == .failure(.unknownCommand), "余分なパスを受け付けた")
    #expect(parse("vox://record/start?text=hello") == .failure(.unexpectedQuery), "本文の指定を受け付けた")
    #expect(parse("vox://record/finish?target=com.example.a") == .failure(.unexpectedQuery),
      "確定に貼り先を受け付けた")
    #expect(
      parse("vox://record/start?target=com.example.a&target=com.example.b") == .failure(.unexpectedQuery),
      "同じ指定が 2 つある URL を受け付けた")
  }

  @Test("URL の利用者・パスワード・ポート・フラグメントは拒む")
  func rejectsExtraComponents() {
    for string in [
      "vox://user:pass@record/finish", "vox://record:123/finish", "vox://record/finish#text=hello",
      "vox://user@record/start"
    ] {
      #expect(parse(string) == .failure(.malformed), "\(string) を受け付けた")
    }
  }

  @Test("設定と録音の状態で、受け付ける操作が決まる")
  func decisionTable() {
    let options = ExternalCommand.StartOptions(finishAfterSilenceMilliseconds: 1_500)
    typealias Row = (ExternalCommand, ResidentPhase, Bool, ExternalCommand.Decision)
    let rows: [Row] = [
      (.start(options), .idle, false, .reject("disabled")),
      (.finish, .recording, false, .reject("disabled")),
      (.start(options), .idle, true, .begin(options)),
      (.toggle(options), .idle, true, .begin(options)),
      (.finish, .recording, true, .finish),
      (.toggle(options), .recording, true, .finish),
      (.start(options), .recording, true, .reject("state_recording")),
      (.finish, .idle, true, .reject("state_idle")),
      (.start(options), .starting, true, .reject("state_starting")),
      (.finish, .starting, true, .reject("state_starting")),
      (.toggle(options), .finishing, true, .reject("state_finishing")),
      (.start(options), .permissionRequired, true, .reject("state_permission_required")),
      (.toggle(options), .error, true, .reject("state_error"))
    ]
    for (command, phase, enabled, expected) in rows {
      #expect(
        command.decision(phase: phase, enabled: enabled) == expected,
        "\(command.kind) \(phase) enabled=\(enabled)")
    }
  }

  @Test("ログに出す操作の名前")
  func kindNames() {
    #expect(ExternalCommand.start(.init()).kind == "start")
    #expect(ExternalCommand.finish.kind == "finish")
    #expect(ExternalCommand.toggle(.init()).kind == "toggle")
  }
}

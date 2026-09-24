// ADR-022。ほかのアプリから届く `vox://record/…` の URL を、録音の操作に読み替える。
// 受け付けるかどうか（設定がオンか）は呼び出し側が決める。ここは形だけを見る。
// why: 本文を受け取る指定は作らない。知らない指定は URL ごと拒み、黙って無視しない。

import Foundation

public enum ExternalCommand: Equatable, Sendable {
  case start(StartOptions)
  case finish
  case toggle(StartOptions)

  public struct StartOptions: Equatable, Sendable {
    /// nil は、URL を受け取った時点の前面アプリ。
    public var targetBundleIdentifier: String?
    /// nil は、無音では確定しない（録音キーで始めた時と同じ）。
    public var finishAfterSilenceMilliseconds: Int?
    /// ADR-023。nil は、話さなくてもやめない（録音キーで始めた時と同じ）。
    public var cancelIfNoSpeechMilliseconds: Int?

    public init(
      targetBundleIdentifier: String? = nil, finishAfterSilenceMilliseconds: Int? = nil,
      cancelIfNoSpeechMilliseconds: Int? = nil
    ) {
      self.targetBundleIdentifier = targetBundleIdentifier
      self.finishAfterSilenceMilliseconds = finishAfterSilenceMilliseconds
      self.cancelIfNoSpeechMilliseconds = cancelIfNoSpeechMilliseconds
    }

    /// 声だけで使う指定が 1 つも無ければ nil（録音キーで始めた時と同じ録音になる）。
    public var handsFree: HandsFreePolicy? {
      guard finishAfterSilenceMilliseconds != nil || cancelIfNoSpeechMilliseconds != nil else {
        return nil
      }
      return HandsFreePolicy(
        finishAfterSilenceMilliseconds: finishAfterSilenceMilliseconds,
        cancelIfNoSpeechMilliseconds: cancelIfNoSpeechMilliseconds)
    }
  }

  public enum ParseError: String, Error, Equatable, Sendable {
    case malformed = "malformed"
    case unsupportedScheme = "unsupported_scheme"
    case unknownCommand = "unknown_command"
    case unexpectedQuery = "unexpected_query"
    case invalidSilence = "invalid_silence"
    case invalidTarget = "invalid_target"
    case invalidNoSpeech = "invalid_no_speech"
  }

  public static let scheme = "vox"
  public static let silenceRange = 800...10_000
  public static let noSpeechRange = 3_000...120_000

  public var kind: String {
    switch self {
    case .start: "start"
    case .finish: "finish"
    case .toggle: "toggle"
    }
  }

  public enum Decision: Equatable, Sendable {
    case begin(StartOptions)
    case finish
    /// ログに出す理由。
    case reject(String)
  }

  /// 設定と録音の状態から、この操作をどう扱うか。開始は待機中だけ、確定は録音中だけ。
  public func decision(phase: ResidentPhase, enabled: Bool) -> Decision {
    guard enabled else { return .reject("disabled") }
    switch (self, phase) {
    case (.start(let options), .idle), (.toggle(let options), .idle): return .begin(options)
    case (.finish, .recording), (.toggle, .recording): return .finish
    case (_, .idle): return .reject("state_idle")
    case (_, .starting): return .reject("state_starting")
    case (_, .recording): return .reject("state_recording")
    case (_, .finishing): return .reject("state_finishing")
    case (_, .permissionRequired): return .reject("state_permission_required")
    case (_, .error): return .reject("state_error")
    }
  }

  public static func parse(_ url: URL) -> Result<Self, ParseError> {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return .failure(.malformed)
    }
    guard components.scheme?.lowercased() == scheme else { return .failure(.unsupportedScheme) }
    guard components.user == nil, components.password == nil, components.port == nil,
      components.fragment == nil
    else { return .failure(.malformed) }
    guard components.host == "record" else { return .failure(.unknownCommand) }
    let items = components.queryItems ?? []
    switch components.path {
    case "/start": return options(from: items).map(Self.start)
    case "/toggle": return options(from: items).map(Self.toggle)
    case "/finish": return items.isEmpty ? .success(.finish) : .failure(.unexpectedQuery)
    default: return .failure(.unknownCommand)
    }
  }

  private static func options(from items: [URLQueryItem]) -> Result<StartOptions, ParseError> {
    let names = items.map(\.name)
    guard Set(names).count == names.count,
      Set(names).isSubset(of: ["target", "finish_after_silence_ms", "cancel_if_no_speech_ms"])
    else { return .failure(.unexpectedQuery) }
    var options = StartOptions()
    for item in items {
      switch item.name {
      case "target":
        guard let value = item.value, isBundleIdentifier(value) else { return .failure(.invalidTarget) }
        options.targetBundleIdentifier = value
      case "cancel_if_no_speech_ms":
        guard let value = item.value, let milliseconds = number(value, in: noSpeechRange) else {
          return .failure(.invalidNoSpeech)
        }
        options.cancelIfNoSpeechMilliseconds = milliseconds
      default:
        guard let value = item.value, let milliseconds = number(value, in: silenceRange) else {
          return .failure(.invalidSilence)
        }
        options.finishAfterSilenceMilliseconds = milliseconds
      }
    }
    return .success(options)
  }

  private static func number(_ value: String, in range: ClosedRange<Int>) -> Int? {
    guard !value.isEmpty, value.allSatisfy({ ("0"..."9").contains($0) }),
      let number = Int(value), range.contains(number)
    else { return nil }
    return number
  }

  private static func isBundleIdentifier(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    return !value.isEmpty && value.count <= 255
      && value.unicodeScalars.allSatisfy(allowed.contains)
  }
}

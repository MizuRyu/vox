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

    public init(targetBundleIdentifier: String? = nil, finishAfterSilenceMilliseconds: Int? = nil) {
      self.targetBundleIdentifier = targetBundleIdentifier
      self.finishAfterSilenceMilliseconds = finishAfterSilenceMilliseconds
    }
  }

  public enum ParseError: String, Error, Equatable, Sendable {
    case malformed = "malformed"
    case unsupportedScheme = "unsupported_scheme"
    case unknownCommand = "unknown_command"
    case unexpectedQuery = "unexpected_query"
    case invalidSilence = "invalid_silence"
    case invalidTarget = "invalid_target"
  }

  public static let scheme = "vox"
  public static let silenceRange = 800...10_000

  public var kind: String {
    switch self {
    case .start: "start"
    case .finish: "finish"
    case .toggle: "toggle"
    }
  }

  public static func parse(_ url: URL) -> Result<Self, ParseError> {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return .failure(.malformed)
    }
    guard components.scheme?.lowercased() == scheme else { return .failure(.unsupportedScheme) }
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
      Set(names).isSubset(of: ["target", "finish_after_silence_ms"])
    else { return .failure(.unexpectedQuery) }
    var options = StartOptions()
    for item in items {
      switch item.name {
      case "target":
        guard let value = item.value, isBundleIdentifier(value) else { return .failure(.invalidTarget) }
        options.targetBundleIdentifier = value
      default:
        guard let value = item.value, let milliseconds = silence(value) else {
          return .failure(.invalidSilence)
        }
        options.finishAfterSilenceMilliseconds = milliseconds
      }
    }
    return .success(options)
  }

  private static func silence(_ value: String) -> Int? {
    guard !value.isEmpty, value.allSatisfy({ ("0"..."9").contains($0) }),
      let number = Int(value), silenceRange.contains(number)
    else { return nil }
    return number
  }

  private static func isBundleIdentifier(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    return !value.isEmpty && value.count <= 255
      && value.unicodeScalars.allSatisfy(allowed.contains)
  }
}

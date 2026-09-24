// ADR-022 / ADR-023。ほかのアプリから始めた録音を、声だけで確定する・やめるかの判定。
// 無音の判定は ADR-020 と同じ「最後に発話レベルを超えた時刻」を使う。どちらの規則も URL で指定した時だけ働く。

public struct HandsFreePolicy: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case keep
    /// 話し終えて黙った。録音キーで確定した時と同じ経路で貼り付ける。
    case finish
    /// 誰も話さず、何も打たなかった。何も貼らずにやめる。
    case cancel
  }

  /// 区切りの締め（ADR-020）が走っている間は確定を待つ。返らない締めを待ち続けないための上限。
  /// 上限の後は録音キーで確定した時と同じ経路（締めの待ちと本文の救済）に任せる。
  public static let finalizeHoldMilliseconds = 1_000.0
  public let finishAfterSilenceMilliseconds: Double?
  public let cancelIfNoSpeechMilliseconds: Double?

  public init(finishAfterSilenceMilliseconds: Int?, cancelIfNoSpeechMilliseconds: Int?) {
    self.finishAfterSilenceMilliseconds = finishAfterSilenceMilliseconds.map(Double.init)
    self.cancelIfNoSpeechMilliseconds = cancelIfNoSpeechMilliseconds.map(Double.init)
  }

  public func action(
    lastSpeechMilliseconds: Double?, startedMilliseconds: Double, now: Double, hasText: Bool,
    paletteOpen: Bool, finalizePendingSince: Double? = nil
  ) -> Action {
    guard !paletteOpen else { return .keep }
    let spoke = lastSpeechMilliseconds.map { $0 >= startedMilliseconds } ?? false
    if !spoke {
      guard let limit = cancelIfNoSpeechMilliseconds, !hasText,
        now - startedMilliseconds >= limit
      else { return .keep }
      return .cancel
    }
    guard let silence = finishAfterSilenceMilliseconds, let lastSpeechMilliseconds, hasText,
      now - lastSpeechMilliseconds >= silence
    else { return .keep }
    guard let finalizePendingSince else { return .finish }
    return now - finalizePendingSince >= Self.finalizeHoldMilliseconds ? .finish : .keep
  }
}

// 確定の締め（finalize）が失敗したときの分岐。

/// 締めに失敗しても、画面に見えている本文は挿入する（見えていたものを消さない）。
public enum FinalizeFallback: Equatable, Sendable {
  /// 通常の確定と同じ挿入経路に渡す本文。
  case insert(String)
  /// 画面にも何も残っていない。失敗として閉じる。
  case giveUp

  public static func decide(head: String, tentative: String, tail: String) -> FinalizeFallback {
    let text = TranscriptBuffer(head: head, tentative: tentative, tail: tail).text
    return text.isEmpty ? .giveUp : .insert(text)
  }
}

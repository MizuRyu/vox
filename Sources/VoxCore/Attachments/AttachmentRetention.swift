// 添付の回収（ADR-017 の決定 5）。期限を過ぎたものと、残りが合計上限を超える分を古い順に落とす。
// why: 確定から数分で消すと、渡したパスを相手が開く前にファイルが無くなる。
// 消すのは寿命の判断なので、ここに純粋な形で置き、列挙と削除は VoxApp に残す。

import Foundation

public struct AttachmentFile: Equatable, Sendable {
  public let name: String
  public let createdAt: Date
  public let byteCount: Int

  public init(name: String, createdAt: Date, byteCount: Int) {
    self.name = name
    self.createdAt = createdAt
    self.byteCount = byteCount
  }
}

public enum AttachmentRetention {
  public static let maximumAgeSeconds = 7.0 * 24 * 60 * 60
  public static let maximumTotalBytes = 500 * 1024 * 1024

  /// 消す名前を古い順に返す。作成日時が未来のものは期限切れにしない。
  public static func purge(
    _ files: [AttachmentFile], now: Date, maximumAgeSeconds: Double = maximumAgeSeconds,
    maximumTotalBytes: Int = maximumTotalBytes
  ) -> [String] {
    let ordered = files.sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    var removed: [String] = []
    var kept: [AttachmentFile] = []
    var keptBytes = 0
    for file in ordered {
      if now.timeIntervalSince(file.createdAt) > maximumAgeSeconds {
        removed.append(file.name)
      } else {
        kept.append(file)
        keptBytes += file.byteCount
      }
    }
    var index = 0
    while keptBytes > maximumTotalBytes, index < kept.count {
      removed.append(kept[index].name)
      keptBytes -= kept[index].byteCount
      index += 1
    }
    return removed
  }
}

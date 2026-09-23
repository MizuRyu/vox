// T23。検索対象として最近使ったフォルダの保存。作業場所が残る私的データなので
// リポジトリ外（~/Library/Application Support/vox/folders.json）に 0600 で置く。
// 並び・上限・絞り込みは VoxCore.FolderHistory が持つ。

import Foundation
import VoxCore

enum FolderHistoryStore {
  /// 20 件ぶんの上限。これを超えるファイルは壊れているとみなして読まない。
  private static let maximumBytes = 64 * 1024

  /// 履歴と同じディレクトリ。検査は一時パスに差し替える。
  nonisolated(unsafe) static var path = defaultPath

  /// why: 記録は確定ごとの detached タスク、読み込みは開くたびの detached タスクで走る。
  /// 読み込み → 更新 → 全文置換が重なると記録を落とすので、ファイルに触る間は直列にする。
  private static let lock = NSLock()

  static var defaultPath: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("vox/folders.json").path
  }

  /// 読めない・壊れたファイルは空として扱い、消えたフォルダは候補から落とす。
  static func load() -> FolderHistory {
    lock.lock()
    defer { lock.unlock() }
    return stored()
  }

  /// パレットから確定した回に 1 度。読み直してから足すので、別の記録を踏まない。
  /// 書き込み失敗はログだけ（入力操作は止めない。MetricsWriter と同じ方針）。
  static func record(_ folder: String, at date: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    var history = stored()
    history.record(folder, at: date)
    do {
      try PrivateFileIO.write(try history.encoded(), to: url)
    } catch {
      // why: PrivateFileSafetyError は URL を持つ。パスは `--log-text` の回だけ出す方針。
      voxLog("folders_error \(reason(of: error)) path=\(voxLoggable(path: url.path))")
    }
  }

  private static func stored() -> FolderHistory {
    guard let data = try? PrivateFileIO.read(url, maximumBytes: maximumBytes) else {
      return FolderHistory()
    }
    return FolderHistory.decoded(from: data).pruned(exists: isDirectory)
  }

  /// パスを含めずに失敗の種類だけ残す。
  private static func reason(of error: Error) -> String {
    guard let error = error as? PrivateFileSafetyError else {
      return String(describing: type(of: error))
    }
    switch error {
    case .symbolicLink: return "symbolic_link"
    case .unsafeFile: return "unsafe_file"
    case .systemCall(let call, let code): return "\(call)_failed errno=\(code)"
    }
  }

  private static var url: URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
  }

  private static func isDirectory(_ folder: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

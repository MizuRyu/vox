// T38-b。作業ツリーと git ディレクトリの変更を FSEvents で受ける。
// 受けたパスから何を読み直すかは VoxCore.ResidentIndexPolicy が決める。
// 実監視は検査しない（利用者の実機確認。docs/MANUAL-VERIFICATION.md PAL-12）。

import CoreServices
import Foundation

/// 生きている間だけ監視する。捨てると stream を止める。
final class FolderWatch {
  /// 変更をまとめる時間。イベントが止んでからこの秒数後に 1 度だけ届く（T38-b の 500ms）。
  static let latencySeconds = 0.5

  /// FSEvents のコールバックに渡す箱。stream が release するまで生きる。
  fileprivate final class Handler {
    let onChange: @Sendable ([String]) -> Void

    init(onChange: @escaping @Sendable ([String]) -> Void) {
      self.onChange = onChange
    }
  }

  private let stream: FSEventStreamRef
  private let queue = DispatchQueue(label: "local.vox.folder-watch")

  init?(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
    guard !paths.isEmpty else { return nil }
    let handler = Handler(onChange: onChange)
    // why: 読み直しの最中に stream を捨てても、飛んでいるコールバックが箱を触る。
    // FSEvents 側に retain させ、release も FSEvents に任せる。
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passRetained(handler).toOpaque(), retain: nil,
      release: { info in
        guard let info else { return }
        Unmanaged<Handler>.fromOpaque(info).release()
      }, copyDescription: nil)
    let flags = UInt32(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault, folderWatchCallback, &context, paths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latencySeconds, flags)
    else {
      Unmanaged<Handler>.fromOpaque(context.info!).release()
      return nil
    }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  deinit {
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}

/// `kFSEventStreamCreateFlagUseCFTypes` なので eventPaths は CFArray<CFString>。
private let folderWatchCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
  guard let info, let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
    return
  }
  Unmanaged<FolderWatch.Handler>.fromOpaque(info).takeUnretainedValue().onChange(paths)
}

// T38-b。作業ツリーと git ディレクトリの変更を FSEvents で受ける。
// 受けた通知から何を読み直すかは VoxCore.ResidentIndexPolicy が決める。
// 実監視は検査しない（利用者の実機確認。docs/MANUAL-VERIFICATION.md PAL-12）。

import CoreServices
import Foundation

/// 1 回分の通知。
struct FolderChange: Sendable {
  let paths: [String]
  /// FSEvents が取りこぼし・集約を申告した回。パスが当てにならないので全部読み直す。
  let rescanRequired: Bool
}

/// 監視の生存。捨てると監視が止まる。
/// why: 常駐索引は「生きているか」だけを持つので、検査は FSEvents を開かない実装を渡せる。
protocol FolderWatching: AnyObject {}

final class FolderWatch: FolderWatching {
  /// 変更をまとめる時間。最初のイベントからこの秒数ぶんを 1 回の通知にする（T38-b の 500ms）。
  static let latencySeconds = 0.5

  /// FSEvents のコールバックに渡す箱。stream が release するまで生きる。
  fileprivate final class Handler {
    let onChange: @Sendable (FolderChange) -> Void

    init(onChange: @escaping @Sendable (FolderChange) -> Void) {
      self.onChange = onChange
    }
  }

  private let stream: FSEventStreamRef
  private let queue = DispatchQueue(label: "local.vox.folder-watch")

  init?(paths: [String], onChange: @escaping @Sendable (FolderChange) -> Void) {
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
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    self.stream = stream
  }

  deinit {
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}

/// 全部読み直すしかない申告。個々のパスは当てにならない。
private let rescanFlags =
  UInt32(kFSEventStreamEventFlagMustScanSubDirs) | UInt32(kFSEventStreamEventFlagUserDropped)
  | UInt32(kFSEventStreamEventFlagKernelDropped) | UInt32(kFSEventStreamEventFlagRootChanged)
  | UInt32(kFSEventStreamEventFlagMount) | UInt32(kFSEventStreamEventFlagUnmount)

/// `kFSEventStreamCreateFlagUseCFTypes` なので eventPaths は CFArray<CFString>。
private let folderWatchCallback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
  guard let info, let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
    return
  }
  let rescanRequired = (0..<count).contains { flags[$0] & rescanFlags != 0 }
  Unmanaged<FolderWatch.Handler>.fromOpaque(info).takeUnretainedValue()
    .onChange(FolderChange(paths: paths, rescanRequired: rescanRequired))
}

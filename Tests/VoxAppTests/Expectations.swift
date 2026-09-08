// 検査で繰り返し使う突き合わせ。失敗位置は呼び出し側に出す。

import AppKit
import Darwin
import Foundation
import Testing

/// symlink・hardlink・FIFO を `root` に用意し、渡した操作がどれも拒否して、
/// リンクの先にある被害者ファイルを 1 バイトも変えないことを見る。
func expectRejectsUnsafeTargets(
  in root: URL, _ operation: (URL) throws -> Void,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let manager = FileManager.default
  let victim = root.appendingPathComponent("victim")
  try Data("keep".utf8).write(to: victim)
  let symbolic = root.appendingPathComponent("symbolic")
  try manager.createSymbolicLink(at: symbolic, withDestinationURL: victim)
  let hard = root.appendingPathComponent("hard")
  try manager.linkItem(at: victim, to: hard)
  let fifo = root.appendingPathComponent("fifo")
  #expect(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture created", sourceLocation: sourceLocation)
  for candidate in [symbolic, hard, fifo] {
    #expect(
      throws: (any Error).self, "unsafe target refused: \(candidate.lastPathComponent)",
      sourceLocation: sourceLocation
    ) {
      try operation(candidate)
    }
  }
  #expect(
    try Data(contentsOf: victim) == Data("keep".utf8),
    "unsafe targets were not modified", sourceLocation: sourceLocation)
}

/// ビューを描く検査はウィンドウを 1 つも開かない。`NSApplication.shared` はプロセスで
/// 共有なので、開いたままにすると並行して走る他の検査が巻き添えになる。
@MainActor
func expectNoVisibleWindows(sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(
    NSApplication.shared.windows.allSatisfy { !$0.isVisible },
    "検証がウィンドウを開いた", sourceLocation: sourceLocation)
}

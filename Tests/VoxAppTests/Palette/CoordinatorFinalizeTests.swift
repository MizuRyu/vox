// A-1。パレットの締めるタスクの持ち回り。閉じた直後にもう一度開いた回で、
// 2 回目の締めが誰にも待たれないまま確定に進んでいないかを見る。

import Foundation
import Testing
@testable import VoxApp

/// 締めるタスクの代わり。`release` を進めるまで返らないので、待ち合わせを順序で確かめられる。
@MainActor
private final class FinalizeGate {
  private(set) var started = 0
  private(set) var finished = 0
  var released = 0

  func run() async {
    started += 1
    let mine = started
    while released < mine {
      try? await Task.sleep(for: .milliseconds(1))
    }
    finished += 1
  }
}

@MainActor
@Suite("Palette: 締めるタスクの待ち合わせ")
struct CoordinatorFinalizeTests {
  @Test("閉じた直後に開き直しても、確定は 2 回目の締めを待つ")
  func reopeningKeepsTheLatestFinalizeTask() async {
    // 検索対象の解決でリポジトリを走査させない（この検査は締めの待ち合わせだけを見る）。
    let allowCurrentDirectory = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = allowCurrentDirectory }

    let gate = FinalizeGate()
    let coordinator = PaletteCoordinator(hud: HudPanel())
    coordinator.finalizeSegment = { await gate.run() }

    coordinator.open(atMilliseconds: 0, typedAt: nil)
    coordinator.close(insert: nil, fileNameOnly: false)
    // 閉じたときの後始末が 1 回目の締めを待ち始めてから開き直す（esc の直後に ⌃P を押す回）。
    for _ in 0..<20 { await Task.yield() }
    coordinator.open(atMilliseconds: 1, typedAt: nil)
    // 1 回目の締めを返し、閉じたときの後始末を走らせる。
    gate.released = 1
    for _ in 0..<50 {
      if gate.finished == 1 { break }
      try? await Task.sleep(for: .milliseconds(1))
    }
    coordinator.close(insert: nil, fileNameOnly: false)

    let waited = Task { @MainActor in
      await coordinator.awaitPendingFinalize()
      return gate.finished
    }
    for _ in 0..<20 { await Task.yield() }
    gate.released = 2
    #expect(await waited.value == 2, "2 回目の締めを待たずに確定へ進んだ")
  }
}

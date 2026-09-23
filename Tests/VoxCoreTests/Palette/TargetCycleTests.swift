// T38-c 検索対象の巡回。キー 1 つで候補を順に進み、一周して元の対象に戻る。
// 輪は打鍵の時点で写し取る（切り替えると候補の並びが変わるため）。

import Foundation
import Testing
import VoxCore

@Suite("Palette: 検索対象の巡回")
struct TargetCycleTests {
  private func target(_ root: String, _ source: PaletteTargetSource = .recent) -> PaletteTarget {
    PaletteTarget(root: root, source: source)
  }

  private func roots(_ cycle: inout TargetCycle, steps: Int) -> [String?] {
    (0..<steps).map { _ in cycle.next()?.root }
  }

  @Test("候補が無い輪は空で、進めても対象を変えない")
  func anEmptyCycleDoesNothing() {
    var cycle = TargetCycle(current: target("/repos/vox", .orca), candidates: [])
    #expect(cycle.isEmpty, "候補が無いのに輪が空でない")
    #expect(cycle.next() == nil, "候補が無いのに次の対象を返した")
  }

  @Test("候補を順に進み、一周して元の対象へ戻る")
  func theCycleReturnsToTheFirstTarget() {
    var cycle = TargetCycle(
      current: target("/repos/vox", .orca),
      candidates: [target("/work/alpha", .worktree), target("/repos/bravo")])
    #expect(!cycle.isEmpty, "候補があるのに輪が空")
    let visited = roots(&cycle, steps: 5)
    #expect(
      visited == ["/work/alpha", "/repos/bravo", "/repos/vox", "/work/alpha", "/repos/bravo"],
      "輪の順が崩れている: \(visited)")
  }

  @Test("進んだ先の source は候補のもの（切り替えの記録に使う）")
  func theCycleKeepsTheCandidateSource() {
    var cycle = TargetCycle(
      current: target("/repos/vox", .orca), candidates: [target("/work/alpha", .worktree)])
    #expect(cycle.next()?.source == .worktree, "候補の source が変わった")
    #expect(cycle.next()?.source == .orca, "一周して戻った対象の source が変わった")
  }

  @Test("対象が未解決なら候補だけを巡る")
  func anUnresolvedTargetCyclesOnlyTheCandidates() {
    var cycle = TargetCycle(current: nil, candidates: [target("/a"), target("/b")])
    let visited = roots(&cycle, steps: 3)
    #expect(visited == ["/a", "/b", "/a"], "未解決の回の輪が違う: \(visited)")
  }
}

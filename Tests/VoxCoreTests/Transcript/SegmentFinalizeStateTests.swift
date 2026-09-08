// A-1。走っている締め（finalize(through:)）の数。確定の前にもう一度待つかの判断に使う。

import Testing
import VoxCore

@Suite("Transcript: 締めの残り")
struct SegmentFinalizeStateTests {
  @Test("始めた締めは終わるまで残る")
  func pendingUntilCompleted() {
    var state = SegmentFinalizeState()
    #expect(!state.hasPending, "何も始めていないのに締めが残っている")
    state.begin()
    #expect(state.hasPending, "始めた締めが残っていない")
    state.complete()
    #expect(!state.hasPending, "終わった締めが残ったまま")
  }

  @Test("時間切れで待つのをやめた締めは、次の締めを始めても残る")
  func overlappingFinalizesAreCounted() {
    var state = SegmentFinalizeState()
    state.begin()
    state.begin()
    state.complete()
    #expect(state.hasPending, "2 つ目の締めが残っていない")
    state.complete()
    #expect(!state.hasPending, "両方終わったのに残っている")
  }

  @Test("終わりが余分に来ても負にならない")
  func completeWithoutBeginIsIgnored() {
    var state = SegmentFinalizeState()
    state.complete()
    state.begin()
    #expect(state.hasPending, "余分な終わりが次の締めを打ち消した")
  }
}

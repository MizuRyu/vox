import Foundation
import Testing
import VoxCore

@Suite("Process: 期限つきの待ち")
struct PollTests {
  @Test("条件が立てば期限を待たずに抜ける")
  func pollStopsOnCondition() async {
    var time = 0.0
    var checks = 0
    await VoxPoll.wait(
      until: {
        checks += 1
        return checks > 2
      },
      deadline: 1_000, step: .milliseconds(1), now: { time += 1; return time })
    #expect(checks == 3, "polling stops at the first satisfied condition")
    #expect(time < 1_000, "polling stops long before the deadline")
  }

  @Test("条件が立たなければ期限で抜ける")
  func pollStopsOnDeadline() async {
    var time = 0.0
    var checks = 0
    await VoxPoll.wait(
      until: {
        checks += 1
        return false
      },
      deadline: 3, step: .milliseconds(1), now: { time += 1; return time })
    #expect(checks == 3, "polling checks the condition until the deadline passes")
  }
}

import Darwin
import Foundation
import Testing
import VoxCore

@Suite("Injection: 貼り付けの安全条件")
struct InjectionSafetyTests {
  @Test("挿入先が変わっていないときだけ貼り付ける")
  func targetSafetyChecks() {
    let original = InjectionTarget(processID: 42, focusedElement: .known(7))
    #expect(
      InjectionSafety.canPost(to: original, current: original, modifiersHeld: false),
      "same PID and focused element permits paste")
    #expect(
      !InjectionSafety.canPost(
        to: original,
        current: InjectionTarget(processID: 99, focusedElement: .known(7)), modifiersHeld: false),
      "changed PID blocks paste")
    #expect(
      !InjectionSafety.canPost(
        to: original,
        current: InjectionTarget(processID: 42, focusedElement: .known(8)), modifiersHeld: false),
      "changed focused element blocks paste")
    #expect(
      !InjectionSafety.canPost(to: original, current: original, modifiersHeld: true),
      "held modifier blocks paste")
    #expect(
      InjectionSafety.canPost(
        to: InjectionTarget(processID: 42, focusedElement: .unknown),
        current: InjectionTarget(processID: 42, focusedElement: .unknown), modifiersHeld: false),
      "unknown accessibility retains PID-level compatibility")
    #expect(
      !InjectionSafety.canPost(
        to: original,
        current: InjectionTarget(processID: 42, focusedElement: .unknown), modifiersHeld: false),
      "known focus becoming unknown blocks paste")

    #expect(
      InjectionSafety.rejection(
        posting: original,
        current: InjectionTarget(processID: 99, focusedElement: .known(8)), modifiersHeld: true)
        == .modifiersHeld,
      "held modifier is reported before the target difference")
    #expect(
      InjectionSafety.rejection(
        posting: original,
        current: InjectionTarget(processID: 99, focusedElement: .known(7)), modifiersHeld: false)
        == .processChanged,
      "changed PID is reported as a process change")
    #expect(
      InjectionSafety.rejection(
        posting: original,
        current: InjectionTarget(processID: 42, focusedElement: .known(8)), modifiersHeld: false)
        == .focusedElementChanged,
      "changed focused element is reported as a focus change")
    #expect(
      InjectionSafety.rejection(
        posting: original,
        current: InjectionTarget(processID: 42, focusedElement: .unknown), modifiersHeld: false)
        == .focusedElementUnreadable,
      "known focus becoming unknown is reported as an unreadable focus")
    #expect(
      InjectionSafety.rejection(
        posting: InjectionTarget(processID: 42, focusedElement: .unknown),
        current: InjectionTarget(processID: 42, focusedElement: .unknown), modifiersHeld: false)
        == nil,
      "unknown accessibility start has no rejection reason")

    var events = 0
    let normalShortcut = InjectionAttempt(original: original)
    #expect(normalShortcut.checkTarget(current: original), "cmd opt space target passes before wait")
    #expect(normalShortcut.readyToPost(current: original, modifiersHeld: false, cancelled: false),
      "released shortcut is ready to post")
    if normalShortcut.readyToPost(current: original, modifiersHeld: false, cancelled: false) {
      events += 1
    }
    #expect(events == 1, "cmd opt space release posts one paste event pair")
    #expect(
      !normalShortcut.readyToPost(current: original, modifiersHeld: true, cancelled: false),
      "held modifier posts zero events")
    #expect(
      !normalShortcut.readyToPost(current: original, modifiersHeld: false, cancelled: true),
      "cancelled attempt posts zero events")
  }

  @MainActor
  @Test("貼り付けの手順は各段で挿入先を確かめ直す")
  func orchestrationChecks() async {
    let original = InjectionTarget(processID: 42, focusedElement: .known(7))
    let changed = InjectionTarget(processID: 99, focusedElement: .known(7))

    var lastResult = InjectionOrchestrationResult.posted
    func run(
      targets: [InjectionTarget], heldAfterWait: Bool = false, cancelled: Bool = false
    ) async -> Int {
      var remaining = targets
      var posts = 0
      lastResult = await InjectionOrchestrator.run(
        original: original,
        currentTarget: { remaining.removeFirst() },
        modifiersHeld: { heldAfterWait },
        isCancelled: { cancelled },
        waitForModifierRelease: {},
        prepareToPost: {},
        postEvent: { posts += 1 })
      return posts
    }

    let beforeWait = await run(targets: [changed])
    #expect(beforeWait == 0, "orchestrator blocks target before wait")
    #expect(
      lastResult == .rejected(.processChanged), "orchestrator reports which condition rejected")
    let afterWait = await run(targets: [original, changed])
    #expect(afterWait == 0, "orchestrator blocks target after wait")
    let beforePost = await run(targets: [original, original, changed])
    #expect(
      beforePost == 0,
      "orchestrator blocks target immediately before post")
    let cancelled = await run(targets: [original], cancelled: true)
    #expect(cancelled == 0, "orchestrator blocks cancellation")
    #expect(lastResult == .rejected(nil), "cancellation carries no rejection reason")
    let held = await run(targets: [original, original], heldAfterWait: true)
    #expect(held == 0, "orchestrator blocks held shortcut modifiers")
    #expect(lastResult == .rejected(.modifiersHeld), "held modifier reaches the orchestrator")
    let released = await run(targets: [original, original, original])
    #expect(released == 1, "orchestrator posts once after cmd opt space release")
  }

  @Test("クリップボードは自分が置いたときだけ書き換える")
  func clipboardChecks() {
    #expect(
      ClipboardSafety.canMutate(expectedChangeCount: 10, currentChangeCount: 10),
      "owned clipboard may be mutated")
    #expect(
      !ClipboardSafety.canMutate(expectedChangeCount: 10, currentChangeCount: 11),
      "new external copy blocks timeout write and restore")
    var writes = 0
    let changed = ClipboardSafety.mutateIfOwned(
      expectedChangeCount: 10, currentChangeCount: 11
    ) { writes += 1 }
    #expect(!changed && writes == 0, "clipboard competition performs zero writes")
    let owned = ClipboardSafety.mutateIfOwned(
      expectedChangeCount: 10, currentChangeCount: 10
    ) { writes += 1 }
    #expect(owned && writes == 1, "owned clipboard performs one write")
    #expect(
      PasteEvidence.receipt.isVerifiedInsertion == false,
      "pasteboard receipt is not insertion verification")
    #expect(
      PasteEvidence.verified.isVerifiedInsertion,
      "explicit verification is distinguished from a request")
    #expect(
      HistoryInsertionStatus.text(verified: false) == "挿入未確認",
      "unverified receipt is not displayed as uninserted")
  }

  @Test("認識の世代が変わった後のコールバックは捨てる")
  func lifecycleChecks() {
    var lifecycle = RecognitionLifecycle()
    let first = lifecycle.begin()
    #expect(lifecycle.accepts(first), "current recognition generation is accepted")
    lifecycle.abort(first)
    #expect(!lifecycle.accepts(first), "aborted recognition generation is rejected")
    let second = lifecycle.begin()
    #expect(!lifecycle.accepts(first), "delayed callback from old generation is rejected")
    #expect(lifecycle.accepts(second), "next recognition generation remains active")
    lifecycle.finish(second)
    #expect(!lifecycle.accepts(second), "finished recognition generation is rejected")
  }

  @Test("履歴ファイルは通常ファイルにだけ非公開で書く")
  func privateFileChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try privateFilePermissionChecks(root: root)
    try expectRejectsUnsafeTargets(in: root) { try PrivateFileIO.append(Data("bad".utf8), to: $0) }
    // FIFO は読み出しも拒否する（開いたまま待たされない）。
    #expect(throws: (any Error).self, "FIFO history read is rejected without blocking") {
      _ = try PrivateFileIO.read(root.appendingPathComponent("fifo"))
    }
    try privateFileTailChecks(root: root)
  }

  private func privateFilePermissionChecks(root: URL) throws {
    try PrivateFileSafety.prepareForAppend(root.appendingPathComponent("history.jsonl"))
    let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
      as? NSNumber
    #expect(directoryMode?.intValue == 0o700, "history directory is private")

    let shared = root.appendingPathComponent("shared")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
    try PrivateFileSafety.prepareForAppend(shared.appendingPathComponent("history.jsonl"))
    let mode = try FileManager.default.attributesOfItem(atPath: shared.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.intValue == 0o755, "existing history parent mode is unchanged")

    let secureFile = root.appendingPathComponent("secure/history.jsonl")
    try PrivateFileIO.append(Data("one\n".utf8), to: secureFile)
    #expect(try PrivateFileIO.read(secureFile) == Data("one\n".utf8),
      "secure regular file append and read")
    let secureMode = try FileManager.default.attributesOfItem(atPath: secureFile.path)[
      .posixPermissions] as? NSNumber
    #expect(secureMode?.intValue == 0o600, "new history file is private")
  }

  /// 末尾読み出しは上限を超えず、行として完成していない断片を返さない。
  private func privateFileTailChecks(root: URL) throws {
    let large = root.appendingPathComponent("large-history")
    let fd = open(large.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    if fd >= 0 {
      _ = lseek(fd, 2 * 1024 * 1024, SEEK_SET)
      _ = write(fd, "partial\nlast-one\nlast-two\n", 26)
      _ = close(fd)
    }
    let tail = try PrivateFileIO.readTail(large, maximumBytes: 64)
    #expect(tail.truncated, "large history tail reports truncation")
    #expect(tail.data.count <= 64, "large history tail remains bounded")
    #expect(
      String(bytes: tail.data, encoding: .utf8) == "last-one\nlast-two\n",
      "large sparse history returns complete tail lines")
    let longLine = root.appendingPathComponent("long-line-history")
    try PrivateFileIO.append(Data(repeating: 0x61, count: 128), to: longLine)
    let noCompleteLine = try PrivateFileIO.readTail(longLine, maximumBytes: 32)
    #expect(noCompleteLine.data.isEmpty, "truncated incomplete history line is discarded")
  }
}

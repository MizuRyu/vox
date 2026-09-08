// T19 のオフスクリーン検証（旧 vox-paste-check）。ウィンドウもキー送出も使わず、
// Injector の pasteboard 経路だけを見る（HUD・CGEventTap・Cmd+V は触らない）。
//
// 名前付きの private pasteboard を使う。利用者の作業中クリップボードを壊さないため。
// promise の解決・changeCount・復元の意味論は general と同じ API 経路を通る。
// 検体は生成した 900 文字。利用者の音声履歴は読み取らない。

import AppKit
import Foundation
import Testing

/// Injector の promise 所有者と退避・復元の写し。**Injector 側を変えたらここも合わせる。**
private final class ProbeOwner: NSObject, NSPasteboardTypeOwner, @unchecked Sendable {
  static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  private let lock = NSLock()
  private var pendingText = ""
  private var callsByType: [String: Int] = [:]

  func set(text: String) {
    lock.withLock {
      pendingText = text
      callsByType = [:]
    }
  }

  var calls: [String: Int] { lock.withLock { callsByType } }

  func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
    let text = lock.withLock {
      callsByType[type.rawValue, default: 0] += 1
      return pendingText
    }
    if type == .string {
      sender.setData(Data(text.utf8), forType: .string)
    } else {
      sender.setData(Data(), forType: type)
    }
  }
}

private enum ConsumerResult {
  case value(Int)
  case failure(String)
}

@MainActor
@Suite("Injection: pasteboard の受け渡し")
struct PasteboardTests {
  private static let sample = String(repeating: "あのこれはテキストの検体です。", count: 60)

  /// 別プロセスの読み手。AppKit は promise の解決を各プロセスのメインスレッドで行う。
  private func consumerScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-paste-consumer-\(UUID().uuidString).js")
    try """
      ObjC.import('AppKit');
      function run(argv) {
        var pasteboard = $.NSPasteboard.pasteboardWithName($(argv[0]));
        var text = pasteboard.stringForType($.NSPasteboardTypeString);
        return String(text.isNil() ? -1 : text.js.length);
      }
      """.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
    guard let items = pasteboard.pasteboardItems else { return [] }
    return items.compactMap { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy.types.isEmpty ? nil : copy
    }
  }

  private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    guard !items.isEmpty else { return }
    pasteboard.writeObjects(items)
  }

  /// 子プロセスを走らせながら、必要なら途中で復元する。promise の解決はこの間に届く。
  private func runConsumer(
    _ command: (executable: String, arguments: [String]),
    restoreAfterMicroseconds: Int?, saved: [NSPasteboardItem], pasteboard: NSPasteboard
  ) -> ConsumerResult {
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return .failure("launch: \(error)")
    }

    let started = Date()
    let restoreAt = restoreAfterMicroseconds.map {
      started.addingTimeInterval(Double($0) / 1_000_000)
    }
    var restored = false
    let deadline = started.addingTimeInterval(2)
    while process.isRunning, Date() < deadline {
      if !restored, let restoreAt, Date() >= restoreAt {
        restore(saved, to: pasteboard)
        restored = true
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
    }
    let timedOut = process.isRunning
    if timedOut {
      process.terminate()
      let terminationDeadline = Date(timeIntervalSinceNow: 0.5)
      while process.isRunning, Date() < terminationDeadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
      }
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
    guard !timedOut else { return .failure("timeout") }
    guard process.terminationStatus == 0 else {
      return .failure("exit=\(process.terminationStatus)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard let value = Int(text) else { return .failure("malformed=\(text)") }
    return .value(value)
  }

  @Test("読み手の失敗は有効な読み取りとして数えない")
  func consumerFailuresAreRejected() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.vox.paste-check.synthetic"))
    for command in [
      ("/bin/sh", ["-c", "exit 7"]), ("/bin/sh", ["-c", "printf not-a-count"]),
      ("/bin/sh", ["-c", "sleep 3"])
    ] {
      let result = runConsumer(
        command, restoreAfterMicroseconds: nil, saved: [], pasteboard: pasteboard)
      if case .value(let value) = result {
        Issue.record("合成した失敗を読み取り \(value) として受理した: \(command.1)")
      }
    }
    pasteboard.releaseGlobally()
  }

  @Test("promise は何度読んでも全長を返し、解決で changeCount は動かない")
  func promiseReadsReturnTheWholeText() {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("dev.vox.paste-check.\(getpid()).\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let text = Self.sample
    let expected = text.count
    let owner = ProbeOwner()
    let saved = snapshot(pasteboard)

    owner.set(text: text)
    _ = pasteboard.declareTypes([.string, ProbeOwner.concealedType], owner: owner)
    let changeAfterDeclare = pasteboard.changeCount
    #expect(pasteboard.string(forType: .string)?.count == expected, "promise_read_once")
    let changeAfterRead = pasteboard.changeCount
    #expect(pasteboard.string(forType: .string)?.count == expected, "promise_read_repeat 2 回目")
    #expect(pasteboard.string(forType: .string)?.count == expected, "promise_read_repeat 3 回目")
    // promise の解決で changeCount が動くと、Injector の復元ガードが復元を飛ばす。
    #expect(changeAfterDeclare == changeAfterRead, "changecount_stable_on_fulfill")

    // 型リストを取ってからデータを読む形（Chromium 系）で、途中に復元が挟まった場合。
    owner.set(text: text)
    _ = pasteboard.declareTypes([.string, ProbeOwner.concealedType], owner: owner)
    let heldItem = pasteboard.pasteboardItems?.first
    restore(saved, to: pasteboard)
    let heldRead = heldItem?.string(forType: .string)
    #expect(
      heldRead == nil || heldRead?.count == expected, "held_item_read_after_restore")

    // 復元後に読み直すと元の内容が返る（途中までにはならない）。
    owner.set(text: text)
    _ = pasteboard.declareTypes([.string, ProbeOwner.concealedType], owner: owner)
    _ = pasteboard.string(forType: .string)
    restore(saved, to: pasteboard)
    let afterRestore = pasteboard.string(forType: .string)
    #expect(
      (afterRestore?.count).map { $0 == 0 || $0 != expected } ?? true,
      "read_after_restore_is_not_partial")
  }

  @Test("復元と並行して読んでも途中までは返らない")
  func restoreNeverTruncatesAConcurrentRead() throws {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("dev.vox.paste-check.\(getpid()).\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let text = Self.sample
    let expected = text.count
    let owner = ProbeOwner()
    let saved = snapshot(pasteboard)
    let script = try consumerScript()
    defer { try? FileManager.default.removeItem(at: script) }
    let consumer = ("/usr/bin/osascript", ["-l", "JavaScript", script.path, pasteboard.name.rawValue])

    var minimum = Int.max
    var partial = 0
    var nilReads = 0
    var failures = 0
    let iterations = 40
    for iteration in 0..<iterations {
      owner.set(text: text)
      _ = pasteboard.declareTypes([.string, ProbeOwner.concealedType], owner: owner)
      // 半分は promise を読み切らせ、半分は即座に復元して nil を許す。
      let restoreDelay = iteration.isMultiple(of: 2) ? 0 : 300_000
      switch runConsumer(
        consumer, restoreAfterMicroseconds: restoreDelay, saved: saved, pasteboard: pasteboard) {
      case .value(-1): nilReads += 1
      case .value(let value) where value == expected: minimum = min(minimum, value)
      case .value: partial += 1
      case .failure: failures += 1
      }
    }
    #expect(
      failures == 0 && partial == 0 && minimum == expected && nilReads > 0,
      """
      restore_never_truncates_concurrent_read \
      failures=\(failures) partial=\(partial) nil=\(nilReads) \
      minLength=\(minimum == Int.max ? -1 : minimum) expected=\(expected)
      """)
    restore(saved, to: pasteboard)
  }

  @Test("実データと長い検体でも長さが保たれ、読み返しが貼り付けた文字数と一致する")
  func lengthsArePreserved() {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("dev.vox.paste-check.\(getpid()).\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let text = Self.sample
    let expected = text.count
    let owner = ProbeOwner()

    // promise ではなく実データを置く経路。
    pasteboard.clearContents()
    pasteboard.setData(Data(text.utf8), forType: .string)
    pasteboard.setData(Data(), forType: ProbeOwner.concealedType)
    #expect(pasteboard.string(forType: .string)?.count == expected, "realdata_read_repeat 1 回目")
    #expect(pasteboard.string(forType: .string)?.count == expected, "realdata_read_repeat 2 回目")

    let long = String(repeating: text, count: 40)
    owner.set(text: long)
    _ = pasteboard.declareTypes([.string, ProbeOwner.concealedType], owner: owner)
    #expect(pasteboard.string(forType: .string)?.count == long.count, "long_text_length_preserved")

    owner.set(text: text)
    _ = pasteboard.declareTypes([.string, ProbeOwner.concealedType], owner: owner)
    #expect(
      pasteboard.string(forType: .string)?.count == expected, "readback_counts_match_pasted")
  }
}

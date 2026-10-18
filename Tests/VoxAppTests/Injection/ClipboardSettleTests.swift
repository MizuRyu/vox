// ADR-027。貼り付けの後、残す設定なら本文を印なしで残し、戻す設定なら元の中身に戻す。
// どちらも、ほかが書いた後と読み返しが合わない回は触らない。名前付きの pasteboard で確かめる。

import AppKit
import Foundation
import Testing
@testable import VoxApp

@MainActor
@Suite("Injection: 貼り付け後のクリップボード")
struct ClipboardSettleTests {
  private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard(name: .init("vox-settle-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    try body(pasteboard)
  }

  /// 貼り付け中と同じ状態（本文 + ConcealedType）を作り、その changeCount を返す。
  private func placeTranscript(_ text: String, on pasteboard: NSPasteboard) -> Int {
    let count = pasteboard.declareTypes([.string, Injector.concealedType], owner: nil)
    pasteboard.setString(text, forType: .string)
    pasteboard.setData(Data(), forType: Injector.concealedType)
    return count
  }

  private func savedItems(_ text: String) -> [NSPasteboardItem] {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    return [item]
  }

  @Test("Keeping leaves the transcript as plain text without the concealed marker")
  func keepDropsConcealedMarker() {
    withPasteboard { pasteboard in
      let count = placeTranscript("合成の本文", on: pasteboard)
      Injector.settle(
        .keep("合成の本文"), on: pasteboard, changeCount: count, expectedCharacters: 5,
        delayMilliseconds: 0)
      #expect(pasteboard.string(forType: .string) == "合成の本文")
      #expect(pasteboard.types?.contains(Injector.concealedType) == false)
    }
  }

  @Test("Restoring puts back what was on the clipboard before the paste")
  func restorePutsBackPrevious() {
    withPasteboard { pasteboard in
      let count = placeTranscript("合成の本文", on: pasteboard)
      Injector.settle(
        .restore(savedItems("前の中身")), on: pasteboard, changeCount: count,
        expectedCharacters: 5, delayMilliseconds: 0)
      #expect(pasteboard.string(forType: .string) == "前の中身")
    }
  }

  @Test("Neither touches the clipboard after something else wrote to it", arguments: [true, false])
  func settleSkipsAfterAnotherWrite(keep: Bool) {
    withPasteboard { pasteboard in
      let count = placeTranscript("合成の本文", on: pasteboard)
      pasteboard.clearContents()
      pasteboard.setString("ほかのコピー", forType: .string)
      Injector.settle(
        keep ? .keep("合成の本文") : .restore(savedItems("前の中身")), on: pasteboard,
        changeCount: count, expectedCharacters: 5, delayMilliseconds: 0)
      #expect(pasteboard.string(forType: .string) == "ほかのコピー")
    }
  }

  @Test("Neither touches the clipboard when the readback does not match", arguments: [true, false])
  func settleSkipsOnReadbackMismatch(keep: Bool) {
    withPasteboard { pasteboard in
      let count = placeTranscript("合成の本文", on: pasteboard)
      Injector.settle(
        keep ? .keep("合成の本文") : .restore(savedItems("前の中身")), on: pasteboard,
        changeCount: count, expectedCharacters: 99, delayMilliseconds: 0)
      #expect(pasteboard.string(forType: .string) == "合成の本文")
      #expect(pasteboard.types?.contains(Injector.concealedType) == true)
    }
  }
}

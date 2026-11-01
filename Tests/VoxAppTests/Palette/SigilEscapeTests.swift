import Foundation
import Testing
@testable import VoxApp

@MainActor
@Suite("Palette: @の取り消し", .serialized)
struct SigilEscapeTests {
  @Test("検索をEscで閉じると、元の位置に空白なしで@を残す")
  func escapeRestoresAtSign() {
    let previous = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = previous }
    let hud = HudPanel()
    hud.model.head = "🙂のIDです"
    let coordinator = PaletteCoordinator(hud: hud, indexes: ResidentIndexStore(), showsPanels: false)
    coordinator.open(atMilliseconds: 0, typedAt: 3)
    coordinator.escape()
    #expect(!coordinator.isOpen)
    #expect(hud.model.transcript.text == "🙂の@IDです")
    #expect(hud.model.transcript.caret == 4)
    #expect(hud.model.hadInput)
    coordinator.reset()
  }

  @Test("選択した文字の上で打った@は、Escでその選択範囲を置き換える")
  func escapeReplacesTheSelection() {
    let previous = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = previous }
    let hud = HudPanel()
    hud.model.head = "連絡先は旧IDです"
    let coordinator = PaletteCoordinator(hud: hud, indexes: ResidentIndexStore(), showsPanels: false)
    coordinator.open(atMilliseconds: 0, typedAt: 4, selectionLength: 3)
    coordinator.escape()
    #expect(hud.model.transcript.text == "連絡先は@です")
    #expect(hud.model.transcript.caret == 5)
    coordinator.reset()
  }

  @Test("検索中に届いた音声を消さず、元の選択範囲だけを@に置き換える")
  func speechDuringSearchPreservesTheSelection() {
    let previous = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = previous }
    let hud = HudPanel()
    hud.model.head = "前旧ID後"
    let coordinator = PaletteCoordinator(hud: hud, indexes: ResidentIndexStore(), showsPanels: false)
    coordinator.open(atMilliseconds: 0, typedAt: 1, selectionLength: 3)
    hud.model.setCaret(1)
    hud.model.commitFinal("音声")
    coordinator.escape()
    #expect(hud.model.transcript.text == "前音声@後")
    coordinator.reset()
  }

  @Test("ショートカットで開いた検索を閉じても@は増えない")
  func shortcutDoesNotRestoreAtSign() {
    let previous = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = previous }
    let hud = HudPanel()
    hud.model.head = "本文"
    let coordinator = PaletteCoordinator(hud: hud, indexes: ResidentIndexStore(), showsPanels: false)
    coordinator.open(atMilliseconds: 0, typedAt: nil)
    coordinator.escape()
    #expect(hud.model.transcript.text == "本文")
    coordinator.reset()
  }

  @Test("ファイルを選んで確定した回には@を残さない")
  func committingAFileDoesNotRestoreAtSign() async {
    let previous = VoxConfig.allowCurrentDirectoryFallback
    VoxConfig.allowCurrentDirectoryFallback = false
    defer { VoxConfig.allowCurrentDirectoryFallback = previous }
    let hud = HudPanel()
    let coordinator = PaletteCoordinator(hud: hud, indexes: ResidentIndexStore(), showsPanels: false)
    coordinator.open(atMilliseconds: 0, typedAt: 0)
    coordinator.close(insert: "Sources/App.swift", fileNameOnly: false)
    for _ in 0..<100 where coordinator.isBusy { await Task.yield() }
    #expect(hud.model.transcript.text == "Sources/App.swift ")
    coordinator.reset()
  }
}

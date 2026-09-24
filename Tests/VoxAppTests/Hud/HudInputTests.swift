// ADR-023。声だけで始めた録音を「入力があった」として残す条件（HUD が録音ごとに記録する）。

import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Hud: 入力があったことの記録")
struct HudInputTests {
  @Test("パレットから差し込むと入力があったことになり、本文を消しても残る")
  func paletteInsertionCountsAsInput() {
    let model = HudModel()
    #expect(!model.hadInput, "新しい HUD が入力ありで始まった")
    model.requestInsertion(PaletteInsertion.insert("Sources/App.swift", into: "", at: 0))
    #expect(model.hadInput, "パレットからの差し込みが入力として残らない")
    model.head = ""
    model.tail = ""
    #expect(model.hadInput, "本文を消したら入力の記録も消えた")
  }
}

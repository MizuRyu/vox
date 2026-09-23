// T38-b 索引の差し替え（常駐索引を先に出し、読み直した索引で置き換える）。
// 並びが変わっても、選んでいた行が別のファイルに入れ替わらないか。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 索引の差し替え")
struct IndexSwapTests {
  private func model(files: [String]) -> PaletteModel {
    let model = PaletteModel()
    model.resolvingTarget = false
    model.target = PaletteTarget(root: "/repos/vox", source: .orca)
    model.setIndex(
      files: files.map { IndexedFile(path: $0) }, changedCount: 0, totalCount: files.count)
    return model
  }

  private func setIndex(_ model: PaletteModel, files: [String], changed: Int = 0) {
    model.setIndex(
      files: files.map { IndexedFile(path: $0) }, changedCount: changed, totalCount: files.count)
  }

  @Test("選んでいた行は差し替え後も同じファイルを指す")
  func theSelectedRowFollowsItsPath() {
    let model = model(files: ["a.swift", "b.swift"])
    model.move(by: 1)
    #expect(model.selectedRow?.file.path == "b.swift", "前提の選択が違う")

    setIndex(model, files: ["b.swift", "a.swift"])
    #expect(
      model.selectedRow?.file.path == "b.swift",
      "差し替えで選択が別のファイルに移った: \(model.selectedRow?.file.path ?? "-")")
  }

  @Test("まだ選んでいない回は差し替え後も先頭のまま")
  func anUntouchedSelectionStaysAtTheTop() {
    let model = model(files: ["a.swift", "b.swift"])
    setIndex(model, files: ["b.swift", "a.swift"])
    #expect(
      model.selectedRow?.file.path == "b.swift",
      "既定の選択が先頭から動いた: \(model.selectedRow?.file.path ?? "-")")
    #expect(model.selection == model.defaultSelection, "既定の選択位置から外れた")
  }

  @Test("選んでいたファイルが消えたら既定の選択に戻る")
  func aVanishedSelectionFallsBackToTheDefault() {
    let model = model(files: ["a.swift", "b.swift"])
    model.move(by: 1)
    setIndex(model, files: ["a.swift"])
    #expect(model.selection == model.defaultSelection, "選択が既定に戻っていない")
    #expect(model.selectedRow?.file.path == "a.swift", "残った行を選んでいない")
  }

  @Test("空の索引に差し替えても選択とプレビューが残らない")
  func anEmptyIndexClearsTheSelection() {
    let model = model(files: ["a.swift", "b.swift"])
    model.move(by: 1)
    setIndex(model, files: [])
    #expect(model.selectedRow == nil, "空の索引で行を選んでいる")
    #expect(model.preview == nil, "空の索引でプレビューが残った")
  }

  @Test("差し替えは Changes のヘッダの件数も入れ替える")
  func theHeaderCountsFollowTheIndex() {
    let model = model(files: ["a.swift"])
    setIndex(model, files: ["a.swift", "b.swift"], changed: 1)
    #expect(model.changedCount == 1, "変更件数が古い")
    #expect(model.totalCount == 2, "全件数が古い")
  }
}

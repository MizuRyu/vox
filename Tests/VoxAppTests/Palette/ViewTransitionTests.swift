// パレットの表示切り替えを実際に描いて確かめる（旧 Tests/Palette/view-transition-tests.py）。
// 生きているビューの再描画結果を、同じ状態から作り直したビューと画素で突き合わせる。

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Palette: 表示の切り替え")
struct ViewTransitionTests {
  private func fixture() -> PaletteModel {
    let model = PaletteModel()
    model.resolvingTarget = false
    model.files = [
      IndexedFile(path: "a.txt"), IndexedFile(path: "Sources/App.swift"),
      IndexedFile(path: "Sources/UI/View.swift"), IndexedFile(path: "Tests/AppTests.swift"),
      IndexedFile(path: "z.txt")
    ]
    model.refreshRows()
    return model
  }

  private func host(_ model: PaletteModel) -> NSHostingView<PaletteView> {
    let view = NSHostingView(rootView: PaletteView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 960, height: 580)
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }

  /// ファイル行だけを画素にする。ピッカーや焦点の装飾とプレビュー面は含めない。
  private func pixels(_ view: NSHostingView<PaletteView>) throws -> Data {
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try #require(bitmap.bitmapData)
    let scale = bitmap.pixelsWide / 960
    let bytesPerPixel = bitmap.bitsPerPixel / 8
    var result = Data()
    for y in (180 * scale)..<(450 * scale) {
      let offset = y * bitmap.bytesPerRow + 18 * scale * bytesPerPixel
      result.append(data.advanced(by: offset), count: 450 * scale * bytesPerPixel)
    }
    return result
  }

  @Test("表示の切り替えと選択が、作り直したビューと同じ絵になる")
  func transitionsRedrawLikeAFreshView() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = fixture()
    let live = host(model)
    let changesPixels = try pixels(live)

    model.setFileViewMode(.tree)
    let expected = fixture()
    expected.setFileViewMode(.tree)
    let expectedTree = try pixels(host(expected))
    #expect(
      changesPixels != expectedTree,
      "fixture visibly distinguishes flat files from folder-first tree")
    #expect(
      try pixels(live) == expectedTree,
      "Changes to Tree redraws folders instead of retaining flat rows")

    model.toggleDirectory(at: 0)
    expected.toggleDirectory(at: 0)
    #expect(try pixels(live) == pixels(host(expected)), "tree expansion redraws children")

    model.toggleDirectory(at: 0)
    expected.toggleDirectory(at: 0)
    #expect(
      try pixels(live) == pixels(host(expected)),
      "tree collapse removes children without stale rows")

    model.query = "View"
    model.refreshRows()
    expected.query = "View"
    expected.refreshRows()
    #expect(
      try pixels(live) == pixels(host(expected)), "query redraws matching ancestors and files")

    var committedPath: String?
    model.onCommit = { path, _ in committedPath = path }
    model.commit(fileNameOnly: false)
    #expect(committedPath == nil, "directory Enter never inserts a file")
    model.move(by: 2)
    model.commit(fileNameOnly: false)
    #expect(
      committedPath == "Sources/UI/View.swift", "keyboard selection commits the displayed file")
    #expect(
      model.selectedDisplayID == "tree:f:Sources/UI/View.swift",
      "scroll target identifies the selected tree file")

    model.query = ""
    model.refreshRows()
    model.setFileViewMode(.changes)
    #expect(try pixels(live) == changesPixels, "Tree to Changes restores flat files")

    model.setFileViewMode(.tree)
    model.resetFileView()
    model.refreshRows()
    #expect(try pixels(live) == changesPixels, "reset preserves Changes display")
    expectNoVisibleWindows()
  }
}

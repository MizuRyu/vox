import AppKit
import Foundation
import SwiftUI
import Testing
import VoxCore
@testable import VoxApp

@MainActor
@Suite("Hud: 録音準備の表示")
struct PreparationViewTests {
  @Test("録音が始まった回と、開始できなかった回に準備表示を残さない")
  func preparationEndsWithRecordingOrNotice() {
    let model = HudModel()
    model.preparation = .loadingModel
    model.isRecording = true
    #expect(model.preparation == nil)
    model.isRecording = false
    model.preparation = .checkingFiles
    model.notice = "録音を開始できませんでした"
    #expect(model.preparation == nil)
  }

  @Test("準備の各段階をライト・ダークでオフスクリーン描画する")
  func preparationStagesRender() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      for stage in [SpeechPreparationStage.checkingFiles, .downloading, .loadingModel, .startingCapture] {
        let model = HudModel()
        model.preparation = stage
        model.status = stage.title
        let view = NSHostingView(rootView: HudView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 150)
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(!model.isRecording)
        #expect(stage.detail.contains("まだ"))
        if let output = ProcessInfo.processInfo.environment["VOX_HUD_PREPARATION_OUTPUT"] {
          let folder = URL(fileURLWithPath: output, isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let file = folder.appendingPathComponent("\(appearance.rawValue)-\(String(describing: stage)).png")
          try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
      }
    }
  }
}

// メニューバー項目の診断行。矩形が画面に重なるかの判断と、行の形を固定する。

import Foundation
import Testing
import VoxCore

@Suite("Resident: メニューバー項目の診断行")
struct StatusItemDiagnosticsTests {
  @Test("画面に重なる矩形は on_screen=true で残る")
  func testFrameOnScreen() {
    #expect(
      StatusItemDiagnostics.framesLine(
        reason: "startup", visible: true,
        button: .init(x: 1_400, y: 958, width: 30, height: 24),
        screens: [
          .init(x: 0, y: 0, width: 1_512, height: 982),
          .init(x: -1_080, y: -100, width: 1_080, height: 1_920)
        ])
        == "status_item_frames reason=startup visible=true button={1400.0,958.0,30.0,24.0} "
        + "on_screen=true screens={0.0,0.0,1512.0,982.0};{-1080.0,-100.0,1080.0,1920.0}",
      "a clickable status item was not recorded as on screen")
  }

  @Test("どの画面とも重ならない矩形は on_screen=false で残る")
  func testFrameOffScreen() {
    #expect(
      StatusItemDiagnostics.framesLine(
        reason: "screen_change", visible: true,
        button: .init(x: 0, y: -22, width: 76, height: 22),
        screens: [.init(x: 0, y: 0, width: 1_512, height: 982)])
        == "status_item_frames reason=screen_change visible=true button={0.0,-22.0,76.0,22.0} "
        + "on_screen=false screens={0.0,0.0,1512.0,982.0}",
      "a status item outside every screen was not recorded as off screen")
  }

  @Test("矩形を取れない回は on_screen=unknown で残る")
  func testFrameUnavailable() {
    #expect(
      StatusItemDiagnostics.framesLine(
        reason: "startup", visible: false, button: nil, screens: [])
        == "status_item_frames reason=startup visible=false button=- on_screen=unknown screens=-",
      "a missing status item frame was reported as a placement judgement")
  }
}

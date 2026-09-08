// HUD。NSPanel(.nonactivatingPanel)。**アプリを activate しない**（前面アプリを変えない。設計書 §4）。
// レイアウトは docs/mock.html 状態 1 の三段（上段: 状態と波形、中段: テキスト、下段: キーヒント）だけ合わせる。
// 配色・書体の再現は M1 の範囲外。
//
// M2 (R14 改訂): 「編集モード」は作らない。**HUD を出している間は常に HUD が key window** で、
// 打った文字はそのまま caret 位置に入る（割り込み）。`.nonactivatingPanel` は NSApp.activate なしで
// key になれるので、`show()` の直後に `makeKey()` する。
// 結果として HUD 表示中は前面アプリにタイプできない。これは意図した挙動（⌃K を押した時点で入力先は vox）。
//
// T11 / T21: 本文は 1 つの NSTextView。時間順の 3 区画 head（通常色・編集可）+ tentative
// （淡色・読み取り専用）+ tail（淡色が出た後に打った分。通常色・編集可）が連続した 1 本のテキスト。
// caret と更新の衝突は、編集を `shouldChangeTextIn` で、caret を `textViewDidChangeSelection` で
// 編集可能域に閉じ込めることで避ける（状態遷移は VoxCore の TranscriptBuffer）。
//
// T18: 右上は `JA` ではなく展開/畳みのボタン。展開すると本文の高さの分だけパネルが伸び（上限は
// 可視領域の半分）、入力中の全文が見える。状態は UserDefaults の `voxHudExpanded`。
// 押しても `NSApp.activate` は呼ばない（前面アプリを変えない）。

import AppKit
import SwiftUI
import VoxCore

private struct LevelMeter: View {
  let level: Double
  private let barCount = 28

  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(0..<barCount, id: \.self) { index in
        let phase = Double((index * 7) % barCount) / Double(barCount)
        let scaled = min(1, level * 14) * (0.35 + 0.65 * abs(sin(phase * .pi)))
        RoundedRectangle(cornerRadius: 1)
          .fill(Color.secondary.opacity(0.55))
          .frame(width: 2, height: max(2, 14 * scaled))
      }
    }
    .frame(height: 16)
  }
}

private struct HudView: View {
  @ObservedObject var model: HudModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        // T19。状態表示・波形・その右の余白（= 右上のボタン以外の上段全体）が展開/畳みの当たり判定。
        // ボタンと当たり判定を重ねない（重ねるとボタンを押したときに二重に効く恐れがある）。
        // ドラッグでウィンドウは動かさない（`isMovableByWindowBackground` は false のまま）。
        HStack(spacing: 10) {
          Circle()
            .fill(Color.red.opacity(0.85))
            .frame(width: 7, height: 7)
          Text(model.status)
            .font(.system(size: 11, weight: .medium))
          LevelMeter(level: model.level)
          Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 18)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleExpanded() }
        Button {
          model.onSettings?()
        } label: {
          Image(systemName: "gearshape")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("設定を開く")
        .accessibilityLabel("voxの設定を開く")
        // T18。`JA` を廃した展開/畳みのボタン。押すと HUD が伸びて入力中の全文が見える。
        Button {
          model.toggleExpanded()
        } label: {
          Image(systemName: model.isExpanded ? "chevron.down" : "chevron.up")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.isExpanded ? "畳む" : "全文を表示")
      }

      Group {
        if let notice = model.notice {
          Text(notice)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        } else {
          TranscriptEditor(model: model)
            .frame(minHeight: 30)
        }
      }
      // 展開中は伸びた分を本文が受け取る（畳んでいる間は従来の 1〜2 行）。
      .frame(
        maxWidth: .infinity, minHeight: 44, maxHeight: model.isExpanded ? .infinity : nil,
        alignment: .topLeading)

      HStack(spacing: 14) {
        hint(model.toggleShortcutLabel, "確定して貼り付け")
        if VoxConfig.sigilTriggerEnabled {
          hint("@", "ファイル")
        }
        hint("esc", "破棄")
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.regularMaterial)
  }

  private func hint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 5) {
      Text(key)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
      Text(label)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
  }
}

/// borderless の NSWindow は既定で key になれない。`makeKey()` を効かせるために上書きする。
/// `.nonactivatingPanel` なので key になってもアプリは activate されない（前面アプリは変わらない）。
private final class VoxPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class HudPanel {
  let model = HudModel()
  private let panel: VoxPanel

  /// 畳んだときの高さ（mock の三段）。展開時はここから本文の分だけ伸びる。
  private static let collapsedHeight: CGFloat = 132

  init() {
    panel = VoxPanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: HudPanel.collapsedHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    // テキストビューにクリックで caret を置けるようにマウスイベントを受ける。
    panel.ignoresMouseEvents = false

    let hosting = NSHostingView(rootView: HudView(model: model))
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = 14
    hosting.layer?.masksToBounds = true
    panel.contentView = hosting

    // T18。右上のボタンで展開状態が変わったら高さを引き直す。
    // NSApp.activate は呼ばない。key は既に HUD が持っているので、focus だけ取り直す。
    model.onExpandedChange = { [weak self] in
      guard let self else { return }
      reposition()
      guard VoxConfig.textEntryEnabled, panel.isVisible else { return }
      panel.makeKey()
      model.focusToken += 1
    }
  }

  var isVisible: Bool { panel.isVisible }

  func show() {
    reposition()
    // orderFrontRegardless + makeKey。makeKeyAndOrderFront も NSApp.activate も呼ばない
    // （アプリを activate すると前面アプリが変わる。R14 の前提）。
    panel.orderFrontRegardless()
    if VoxConfig.textEntryEnabled {
      panel.makeKey()
      model.focusToken += 1
    }
  }

  /// T18。展開中は本文が増えたら高さを引き直す（上限は可視領域の半分）。
  /// 1px 未満の差では触らない（tentative の更新ごとに setFrame を投げない）。
  func refreshExpandedHeight() {
    guard model.isExpanded, panel.isVisible, let screen = NSScreen.main else { return }
    let height = expandedHeight(width: panel.frame.width, visible: screen.visibleFrame)
    guard abs(height - panel.frame.height) >= 1 else { return }
    reposition()
  }

  /// M3。パレットを閉じたあとに key を取り直す（パレットが key を持っていった）。
  func makeKeyAgain() {
    guard VoxConfig.textEntryEnabled, panel.isVisible else { return }
    panel.orderFrontRegardless()
    panel.makeKey()
    model.focusToken += 1
  }

  /// 確定の直前に key を返す。この後 R16 の activate 確認 → Cmd+V。
  func resignKeyForInsertion() {
    panel.makeFirstResponder(nil)
    panel.resignKey()
  }

  func hide() {
    resignKeyForInsertion()
    panel.orderOut(nil)
  }

  func reset(status: String) {
    model.status = status
    // T21。head / tentative / tail をまとめて空にする。前の回を持ち越さない。
    model.clearText()
    model.notice = nil
    model.level = 0
    model.typedCharacters = 0
    // T15。前回の変換が破棄されたまま HUD が閉じた場合に、esc の横取り判定が残らないよう明示的に戻す。
    model.isComposing = false
    model.isRecording = false
    model.resetToken += 1
  }

  private func reposition() {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let width = min(680, visible.width - 80)
    let height =
      model.isExpanded ? expandedHeight(width: width, visible: visible) : Self.collapsedHeight
    let origin = NSPoint(
      x: visible.midX - width / 2,
      y: visible.minY + 24
    )
    panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
  }

  /// T18。展開時の高さ。本文（3 領域の全文）が要る高さを測り、可視領域の半分を上限にする。
  /// 内容がそれより短ければ内容に合わせる（畳んだ高さは下限）。
  private func expandedHeight(width: CGFloat, visible: NSRect) -> CGFloat {
    let text = model.transcript.text
    // 本文の幅は HudView の横 padding（18 * 2）を引いた分。
    let bounding = NSAttributedString(
      string: text.isEmpty ? " " : text, attributes: TranscriptEditor.committedAttributes
    ).boundingRect(
      with: NSSize(width: max(1, width - 36), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    // 本文以外（上段・下段・padding）が占める分。畳んだ高さのうち本文枠の 44 を除いた残り。
    let chrome = Self.collapsedHeight - 44
    let needed = ceil(bounding.height) + chrome
    return min(visible.height / 2, max(Self.collapsedHeight, needed))
  }
}

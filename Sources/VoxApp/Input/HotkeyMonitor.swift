// ホットキー。自前 CGEventTap（Sources/VoxM0FactCheck の events サブコマンドで
// 動作確認済みの断片を土台にする）。
// トグルのキーは設定画面と起動引数で変更できる（直起動の既定 ⌘⇧Space）。esc は HUD 表示中だけ拾う。
//
// 設定保存後は同じ event tap の照合キーを更新する。録音中は次回から反映する。

import ApplicationServices
import CoreGraphics
import Foundation
import VoxCore

/// `CGEvent` を隔離越しに渡すための箱。
private struct EventBox: @unchecked Sendable {
  let event: CGEvent
}

enum HotkeyEvent {
  case toggle(atMilliseconds: Double)
  case escape(atMilliseconds: Double)
  /// M3。コマンドパレット（既定 ⌃P）。
  case palette(atMilliseconds: Double)
}

/// tap のコールバックで決められる分だけ。時刻を付けて出来事にするのは呼び出し側（tap の外）。
enum HotkeyDecision {
  /// 前面アプリにそのまま渡す。
  case pass
  /// 飲むが何も起こさない（キーリピート）。
  case consume
  case toggle
  case palette
  case escape
}

enum HotkeyError: Error, CustomStringConvertible {
  case tapCreationFailed
  case invalidChord(String)

  var description: String {
    switch self {
    case .tapCreationFailed: "CGEventTap を作成できなかった"
    case .invalidChord(let spec): "ショートカットの指定を解釈できない: \(spec)"
    }
  }
}

typealias KeyChord = HotkeyBinding

extension HotkeyBinding {
  func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
    self.keyCode == keyCode
      && flags.contains(.maskCommand) == command
      && flags.contains(.maskShift) == shift
      && flags.contains(.maskControl) == control
      && flags.contains(.maskAlternate) == option
  }
}

@MainActor
final class HotkeyMonitor {
  private static let escapeKeyCode: Int64 = 53

  /// トグルのキー。MainActor 上で更新でき、tap の再登録は不要。
  var toggleChord: KeyChord = .commandShiftSpace
  /// パレットのキー。同上。
  var paletteChord: KeyChord = .controlP

  /// tap コールバックから同期的に呼ぶ。重い処理はしないこと（イベント配送が遅れる）。
  var onEvent: ((HotkeyEvent) -> Void)?
  /// esc を飲むかどうか。HUD 表示中だけ true。
  var wantsEscape: () -> Bool = { false }
  /// パレットキーを飲むかどうか。録音中だけ true（HUD 非表示時は素通し。指示書）。
  var wantsPalette: () -> Bool = { false }

  var isSuspended: () -> Bool = { false }

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var runLoop: CFRunLoop?

  func start() throws {
    guard tap == nil else { return }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else { return Unmanaged.passUnretained(event) }
      let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
      // `CGEvent` は Sendable ではない。隔離を越えて渡すだけで、渡した先でしか触らない。
      let box = EventBox(event: event)
      // tap のソースは main run loop に付けているので、このコールバックは main thread で走る。
      let consume = MainActor.assumeIsolated { monitor.handle(type: type, event: box.event) }
      return consume ? nil : Unmanaged.passUnretained(event)
    }

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      throw HotkeyError.tapCreationFailed
    }
    self.tap = tap

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    let runLoop = CFRunLoopGetCurrent()
    self.source = source
    self.runLoop = runLoop
    CFRunLoopAddSource(runLoop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    voxLog(
      "hotkey toggle=\(toggleChord) key_code=\(toggleChord.keyCode) "
        + "palette=\(paletteChord) palette_key_code=\(paletteChord.keyCode)")
  }

  func stop() {
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source, let runLoop {
      CFRunLoopRemoveSource(runLoop, source, .commonModes)
      CFRunLoopSourceInvalidate(source)
    }
    CFMachPortInvalidate(tap)
    source = nil
    runLoop = nil
    self.tap = nil
  }

  /// 戻り値 true でイベントを飲む（前面アプリに渡さない）。
  private func handle(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return false
    }
    guard type == .keyDown, !isSuspended() else { return false }

    let now = voxNowMilliseconds()
    let hotkeyEvent: HotkeyEvent
    switch Self.decide(
      keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
      isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
      toggle: toggleChord, palette: paletteChord, wantsPalette: wantsPalette(),
      wantsEscape: wantsEscape()) {
    case .pass: return false
    case .consume: return true
    case .toggle:
      voxLog("hotkey toggle_pressed at_ms=\(now)")
      hotkeyEvent = .toggle(atMilliseconds: now)
    case .palette:
      voxLog("hotkey palette_pressed at_ms=\(now)")
      hotkeyEvent = .palette(atMilliseconds: now)
    case .escape:
      hotkeyEvent = .escape(atMilliseconds: now)
    }
    // 録音の開始は AX で挿入先を捕まえる。tap の中で呼ぶと前面アプリが応答するまで
    // キーボード全体の配送が止まるので、次のホップに逃がす（A-2）。
    Task { @MainActor in self.onEvent?(hotkeyEvent) }
    return true
  }

  /// 飲むかどうかと、何を起こすか。AX にもアプリ状態にも触らない（tap の中で決める分）。
  /// キーリピートは飲むだけで出来事にしない。長押しで開始直後の確定に入らないため（A-4）。
  static func decide(
    keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool,
    toggle: KeyChord, palette: KeyChord, wantsPalette: Bool, wantsEscape: Bool
  ) -> HotkeyDecision {
    if toggle.matches(keyCode: keyCode, flags: flags) {
      return isAutorepeat ? .consume : .toggle
    }
    if palette.matches(keyCode: keyCode, flags: flags), wantsPalette {
      return isAutorepeat ? .consume : .palette
    }
    if keyCode == Self.escapeKeyCode, !flags.contains(.maskCommand), !flags.contains(.maskShift),
      !flags.contains(.maskControl), !flags.contains(.maskAlternate), wantsEscape {
      return isAutorepeat ? .consume : .escape
    }
    // Tab は飲まない。HUD が key window なのでテキストビューにそのまま渡る（R14 改訂）。
    return .pass
  }
}

/// 起動オプションから渡す設定。Launch/Startup.swift が `application.run()` の前に設定する。
enum VoxConfig {
  /// Opt-in metadata diagnostics. Never retains audio samples or recognized text.
  @MainActor static var audioDiagnosticsEnabled = false
  /// Finder launch must not treat its incidental cwd (often `/`) as a repository.
  nonisolated(unsafe) static var allowCurrentDirectoryFallback = true
  nonisolated(unsafe) static var toggleChord: KeyChord = .commandShiftSpace
  /// M3 コマンドパレットのキー (--palette-key)。
  nonisolated(unsafe) static var paletteChord: KeyChord = .controlP
  /// パレットの検索対象が特定できないときのフォールバック先 (--repo、複数指定可)。
  nonisolated(unsafe) static var fallbackRepositories: [String] = []
  /// 確定テキストの全文を stderr に出す。発話内容は私的なので既定はオフ (--log-text で有効)。
  nonisolated(unsafe) static var logFinalText = false
  /// R18 フィラー除去 (--no-filler-removal で無効)。
  nonisolated(unsafe) static var fillerRemovalEnabled = true
  /// T13 `@` の打鍵でパレットを開く (--no-sigil-trigger で無効。⌃P だけになる)。
  nonisolated(unsafe) static var sigilTriggerEnabled = true
  /// R14 のテキスト入力の割り込み (--no-edit-mode で無効)。
  /// 無効にすると HUD を key window にしないので、キーは前面アプリに流れる（M1 の挙動）。
  nonisolated(unsafe) static var textEntryEnabled = true
}

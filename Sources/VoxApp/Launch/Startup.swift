// vox — M1/M2。ターミナルから起動して常駐し、トグルキーで HUD + 速報レーンを開閉する。
// 指示書: docs/tasks/T8-m1-hud-streaming-insert.md, docs/tasks/T9-m2-hardening.md

import AppKit
import ApplicationServices
import Foundation
import OSLog
import VoxCore

/// `Sources/Vox/main.swift` の入口。引数を解釈し、常駐を組み立てて NSApplication を回す。
@MainActor
public func runVox(arguments: [String]) -> Never {
  voxPrimeClock()
  guard let options = parseOptions(arguments) else {
    voxWrite(Data((usage() + "\n").utf8), to: .standardError)
    exit(64)
  }
  let isBundled = Bundle.main.bundleURL.pathExtension == "app"
  let (log, logError) = installApplicationLog(isBundled: isBundled)
  VoxConfig.fallbackRepositories = options.fallbackRepositories
  VoxConfig.allowCurrentDirectoryFallback = ResidentPalettePolicy.allowsCurrentDirectoryFallback(
    isBundled: isBundled)

  // 履歴を出すだけのモード。権限は要らないのでゲートより前に処理する。
  if let limit = options.printHistoryLimit {
    exit(HistoryPrinter.print(path: options.historyPath, limit: limit))
  }

  let settings = makeSettingsController(options: options)
  if !options.settingsOnly && !isBundled { requireInputPermissions() }

  let application = NSApplication.shared
  application.setActivationPolicy(isBundled ? .regular : .accessory)
  let delegate = ResidentCoordinator(
    metricsPath: options.metricsPath ?? defaultMetricsPath(isBundled: isBundled),
    historyPath: options.historyPath, settings: settings, settingsOnly: options.settingsOnly,
    isBundled: isBundled, log: log, logError: logError)
  let mainMenu = makeMainMenu(target: delegate)
  application.mainMenu = mainMenu
  application.windowsMenu = mainMenu.items.first { $0.submenu?.title == "Window" }?.submenu
  application.delegate = delegate
  application.run()
  exit(0)
}

func defaultMetricsPath(isBundled: Bool) -> String {
  guard isBundled else { return directLaunchMetricsPath }
  let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
  return ResidentPaths.defaultMetricsURL(applicationSupport: base).path
}

private func installApplicationLog(isBundled: Bool) -> (AppLogRouter?, String?) {
  guard isBundled else { return (nil, nil) }
  do {
    return (try AppLogRouter.install(), nil)
  } catch {
    Logger(subsystem: "local.vox.app", category: "startup").error(
      "Unable to initialize the private Vox log")
    return (nil, "診断ログを準備できませんでした")
  }
}

@MainActor
private func makeSettingsController(options: VoxOptions) -> SettingsController {
  let defaults = HotkeyConfiguration.standard
  let store = SettingsStore.standard
  let startup: SettingsStartup
  do {
    startup = try SettingsStartup(store: store, defaults: defaults,
      overrides: options.hotkeyOverrides, settingsOnly: options.settingsOnly)
  } catch {
    voxWrite(Data((error.localizedDescription + "\n").utf8), to: .standardError)
    exit(64)
  }
  if let warning = startup.warning {
    voxWrite(Data((warning + "\n").utf8), to: .standardError)
  }
  VoxConfig.toggleChord = startup.configuration.toggle
  VoxConfig.paletteChord = startup.configuration.palette
  return SettingsController(store: store, defaults: defaults,
    overrides: options.hotkeyOverrides, configuration: startup.configuration)
}

/// 権限のゲート。足りなければ手順を出して終了する（指示書「ホットキー」）。
private func requireInputPermissions() {
  _ = CGRequestListenEventAccess()
  _ = CGRequestPostEventAccess()
  let axTrusted = AXIsProcessTrusted()
  let listenAccess = CGPreflightListenEventAccess()
  let postAccess = CGPreflightPostEventAccess()
  voxLog(
    "permissions ax_process_trusted=\(axTrusted) listen_event_access=\(listenAccess) "
      + "post_event_access=\(postAccess)")
  guard !(axTrusted && listenAccess && postAccess) else { return }
  let message = """

  アクセシビリティと入力監視が許可されていないため起動できません。次の手順で許可してください:
    1. システム設定 → プライバシーとセキュリティ → アクセシビリティ を開く
    2. このコマンドを起動したターミナルアプリ（Terminal / iTerm2 / Ghostty など）をオンにする
    3. 同じ画面の 入力監視 でも同じターミナルアプリをオンにする
    4. ターミナルアプリを再起動してから、もう一度 ./.build/debug/Voxを実行する

  現在の状態: accessibility=\(axTrusted) input_monitoring=\(listenAccess) post_events=\(postAccess)

  """
  voxWrite(Data(message.utf8), to: .standardError)
  exit(1)
}

// ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z は「Edit メニューの項目」として配送される AppKit の仕様のため、
// メインメニューが無い accessory アプリでは HUD のテキストビューに届かない (実機でユーザーが指摘)。
// bundled app では表示し、CLI の accessory 起動でも Edit action を配送できるメニューを持たせる。
@MainActor
func makeMainMenu(target: ResidentCoordinator) -> NSMenu {
  let mainMenu = NSMenu()
  let appItem = NSMenuItem()
  let appMenu = NSMenu(title: "Vox")
  let settingsItem = NSMenuItem(title: "設定…", action: #selector(ResidentCoordinator.showSettings(_:)),
    keyEquivalent: ",")
  settingsItem.keyEquivalentModifierMask = [.command]
  settingsItem.target = target
  appMenu.addItem(settingsItem)
  let quitItem = NSMenuItem(title: "Voxを終了", action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q")
  quitItem.keyEquivalentModifierMask = [.command]
  appMenu.addItem(quitItem)
  appItem.submenu = appMenu
  mainMenu.addItem(appItem)
  let editItem = NSMenuItem()
  let editMenu = NSMenu(title: "Edit")
  editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
  editMenu.addItem(NSMenuItem.separator())
  editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
  editItem.submenu = editMenu
  mainMenu.addItem(editItem)
  // ⌘W も Edit と同じ理由でメニュー項目としてしか届かない。閉じられない HUD では
  // performClose: の validate が落ちるので、項目は自然に無効になる。
  let windowItem = NSMenuItem()
  let windowMenu = NSMenu(title: "Window")
  let closeItem = NSMenuItem(title: "閉じる", action: #selector(NSWindow.performClose(_:)),
    keyEquivalent: "w")
  closeItem.keyEquivalentModifierMask = [.command]
  windowMenu.addItem(closeItem)
  windowItem.submenu = windowMenu
  mainMenu.addItem(windowItem)
  return mainMenu
}

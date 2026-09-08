import AppKit
import ServiceManagement
import VoxCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  var onPrimaryAction: (() -> Void)?
  var onShowSettings: (() -> Void)?
  var onRequestPermissions: (() -> Void)?
  var onQuit: (() -> Void)?
  var onMenuWillOpen: (() -> Void)?
  var diagnosticsEnabled: (() -> Bool)?
  var onSetDiagnosticsEnabled: ((Bool) -> Void)?
  var logURL: (() -> URL?)?

  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let menu = NSMenu()
  private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let primary = NSMenuItem(title: "", action: #selector(runPrimary), keyEquivalent: "")
  private let permissions = NSMenuItem(
    title: "権限を確認…", action: #selector(requestPermissions), keyEquivalent: "")
  private let login = NSMenuItem(
    title: "ログイン時に開く", action: #selector(toggleLoginItem), keyEquivalent: "")
  private let diagnostics = NSMenuItem(
    title: "音声の診断を記録（音声は保存しません）", action: #selector(toggleDiagnostics),
    keyEquivalent: "")
  private let openLog = NSMenuItem(
    title: "診断ログを開く…", action: #selector(openLogAction), keyEquivalent: "")
  private let loginService = LoginItemService()
  private var phase: ResidentPhase = .idle
  private var permissionRequestInFlight = false

  override init() {
    super.init()
    statusItem.button?.image = NSImage(
      systemSymbolName: "waveform", accessibilityDescription: "Vox")
    statusItem.button?.toolTip = "Vox（待機中）"
    menu.autoenablesItems = false
    status.isEnabled = false
    menu.delegate = self
    for item in [primary, permissions, login, diagnostics] { item.target = self }
    menu.addItem(status)
    menu.addItem(primary)
    menu.addItem(permissions)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "設定…", action: #selector(showSettings), keyEquivalent: ","))
    menu.items.last?.keyEquivalentModifierMask = [.command]
    menu.items.last?.target = self
    menu.addItem(login)
    menu.addItem(diagnostics)
    openLog.target = self
    menu.addItem(openLog)
    menu.addItem(NSMenuItem.separator())
    let quit = NSMenuItem(title: "Voxを終了", action: #selector(quit), keyEquivalent: "q")
    quit.keyEquivalentModifierMask = [.command]
    quit.target = self
    menu.addItem(quit)
    statusItem.menu = menu
    update(phase: .idle)
  }

  func update(phase: ResidentPhase, detail: String? = nil) {
    self.phase = phase
    let title = detail ?? ResidentPresentation.statusTitle(for: phase)
    status.title = "状態: \(title)"
    primary.title = ResidentPresentation.primaryActionTitle(for: phase)
    primary.isEnabled = !permissionRequestInFlight && ResidentPresentation.canToggleRecording(in: phase)
    permissions.isHidden = phase != .permissionRequired && phase != .error
    statusItem.button?.toolTip = "Vox（\(title)）"
    statusItem.button?.image = NSImage(
      systemSymbolName: phase == .recording ? "waveform.circle.fill" : "waveform",
      accessibilityDescription: "Vox（\(title)）")
  }

  func configureLog(url: URL?, error: String?) {
    logURL = { url }
    openLog.isEnabled = url != nil
    openLog.title = error ?? "診断ログを開く…"
    openLog.toolTip = error
  }

  func setPermissionRequestInFlight(_ inFlight: Bool) {
    permissionRequestInFlight = inFlight
    primary.isEnabled = !inFlight && ResidentPresentation.canToggleRecording(in: phase)
    permissions.isEnabled = !inFlight
  }

  func menuWillOpen(_ menu: NSMenu) {
    onMenuWillOpen?()
    refreshLoginItem()
    diagnostics.state = diagnosticsEnabled?() == true ? .on : .off
  }

  private func refreshLoginItem() {
    login.title = "ログイン時に開く"
    switch loginService.state {
    case .disabled:
      login.state = .off
      login.isEnabled = true
      login.toolTip = nil
    case .enabled:
      login.state = .on
      login.isEnabled = true
      login.toolTip = nil
    case .requiresApproval:
      login.state = .mixed
      login.isEnabled = true
      login.toolTip = "システム設定で許可が必要です"
    case .unavailable:
      login.state = .off
      login.isEnabled = false
      login.toolTip = "Vox.appでのみ使えます"
    }
  }

  @objc private func runPrimary() {
    if phase == .permissionRequired {
      onRequestPermissions?()
    } else {
      onPrimaryAction?()
    }
  }
  @objc private func requestPermissions() { onRequestPermissions?() }
  @objc private func showSettings() { onShowSettings?() }
  @objc private func quit() { onQuit?() }
  @objc private func toggleDiagnostics() {
    let enabled = diagnosticsEnabled?() != true
    onSetDiagnosticsEnabled?(enabled)
    diagnostics.state = enabled ? .on : .off
  }
  @objc private func openLogAction() {
    guard let url = logURL?() else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func toggleLoginItem() {
    let state = loginService.state
    switch ResidentLoginPolicy.action(for: state) {
    case .openSystemSettings:
      SMAppService.openSystemSettingsLoginItems()
      return
    case .none:
      return
    case .register:
      do {
        try loginService.register()
        refreshLoginItem()
      } catch {
        login.title = "ログイン時に開く（登録できませんでした）"
        login.toolTip = "ログイン項目に登録できませんでした。システム設定の「ログイン項目」を確認してください。"
      }
    case .unregister:
      do {
        try loginService.unregister()
        refreshLoginItem()
      } catch {
        login.title = "ログイン時に開く（解除できませんでした）"
        login.toolTip = "ログイン項目から外せませんでした。システム設定の「ログイン項目」を確認してください。"
      }
    }
  }
}

// 常駐 UI の持ち主。メニューバー、操作ウィンドウ、権限チェックリスト、ログイン項目の起動を束ねる。
// 録音そのものは VoxController が持ち、ここは phase を受け取って表示に反映するだけ。

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import VoxCore

@MainActor
final class ResidentCoordinator: NSObject, NSApplicationDelegate {
  private let metricsPath: String
  private let historyPath: String
  private let settings: SettingsController
  private let settingsOnly: Bool
  private let isBundled: Bool
  /// stderr のリダイレクトと肥大化の抑止はこのインスタンスが生きている間だけ効く。
  private let log: AppLogRouter?
  private let logError: String?
  private var controller: VoxController?
  private var settingsLauncher: SettingsLauncher?
  private var statusItemController: StatusItemController?
  private var appControlsWindow: AppControlsWindow?
  private var instanceLock: AppInstanceLock?
  private var isTerminating = false
  private var permissionRequestInFlight = false
  private var controllerStarted = false
  private var lastSetupPermissions: SetupPermissions?

  init(
    metricsPath: String, historyPath: String, settings: SettingsController, settingsOnly: Bool,
    isBundled: Bool, log: AppLogRouter?, logError: String?
  ) {
    self.metricsPath = metricsPath
    self.historyPath = historyPath
    self.settings = settings
    self.settingsOnly = settingsOnly
    self.isBundled = isBundled
    self.log = log
    self.logError = logError
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      if settingsOnly {
        let launcher = SettingsLauncher(controller: settings)
        settingsLauncher = launcher
        launcher.open()
        return
      }
      do {
        instanceLock = try AppInstanceLock(url: AppInstanceLock.standardURL)
      } catch AppInstanceLock.LockError.alreadyRunning {
        voxWrite(Data("Voxはすでに起動しています。\n".utf8), to: .standardError)
        NSApplication.shared.terminate(nil)
        return
      } catch {
        voxWrite(Data("Voxの多重起動を確認できませんでした。\n".utf8), to: .standardError)
        NSApplication.shared.terminate(nil)
        return
      }
      let writer = MetricsWriter(path: metricsPath)
      let historyWriter = HistoryWriter(path: historyPath)
      let controller = VoxController(metrics: writer, history: historyWriter, settings: settings)
      self.controller = controller
      let status = StatusItemController()
      statusItemController = status
      let controls = AppControlsWindow()
      appControlsWindow = controls
      controller.onResidentPhaseChange = { [weak self, weak status, weak controls] phase, detail in
        status?.update(phase: phase, detail: detail)
        controls?.update(phase: phase, detail: detail)
        if phase == .idle { self?.refreshSetupPermissions() }
      }
      wireStatusItem(status, controller: controller)
      wireControlsWindow(controls)
      status.update(phase: .starting)
      controls.update(phase: .starting)
      if ResidentControlPolicy.shouldShowWindow(
        for: .startup(isBundled: isBundled, launchedAtLogin: launchedAsLoginItem()),
        permissionsReady: inputPermissionsReady && microphoneAuthorization() == .authorized) {
        controls.show()
      }
      startController(
        controller, status: status, controls: controls, writer: writer,
        historyWriter: historyWriter)
    }
  }

  @MainActor
  private func wireStatusItem(_ status: StatusItemController, controller: VoxController) {
    status.onMenuWillOpen = { [weak controller] in controller?.captureMenuTarget() }
    status.onShowSettings = { [weak self] in self?.settings.show() }
    status.onPrimaryAction = { [weak self, weak controller] in
      self?.requestPermissionsAndPerformPrimary(using: controller)
    }
    status.onRequestPermissions = { [weak self] in self?.showSetup() }
    status.onQuit = { NSApplication.shared.terminate(nil) }
    status.diagnosticsEnabled = { VoxConfig.audioDiagnosticsEnabled }
    status.onSetDiagnosticsEnabled = { enabled in
      VoxConfig.audioDiagnosticsEnabled = enabled
      voxLog("audio_diagnostics enabled=\(enabled)")
    }
    status.configureLog(url: log?.url, error: logError)
  }

  @MainActor
  private func wireControlsWindow(_ controls: AppControlsWindow) {
    controls.onShowSettings = { [weak self] in self?.settings.show() }
    controls.onRequestPermission = { [weak self] permission in
      self?.requestSetupPermission(permission)
    }
    controls.onRefreshPermissions = { [weak self] userInitiated in
      self?.refreshSetupPermissions(retryHotkeys: userInitiated)
    }
    controls.updatePermissions(currentSetupPermissions())
    controls.onQuit = { NSApplication.shared.terminate(nil) }
  }

  @MainActor
  private func startController(
    _ controller: VoxController, status: StatusItemController, controls: AppControlsWindow,
    writer: MetricsWriter, historyWriter: HistoryWriter
  ) {
    Task { @MainActor in
      guard !self.isTerminating else { return }
      if !isBundled, !(await ensureMicrophoneAccess()) {
        voxWrite(Data("マイクの使用が許可されていないため起動できません。\n".utf8), to: .standardError)
        NSApplication.shared.terminate(nil)
        return
      }
      guard !self.isTerminating else { return }
      do {
        // Complete callback/settings wiring even if event-tap creation later fails.
        // The checklist enables hotkeys after all required grants are confirmed.
        try controller.start(enableHotkeys: false)
        self.controllerStarted = true
      } catch {
        status.update(phase: .error, detail: "起動できませんでした。Voxを終了して開き直してください")
        controls.update(phase: .error, detail: "起動できませんでした。Voxを終了して開き直してください")
        return
      }
      self.refreshSetupPermissions(retryHotkeys: true)
      print(
        "vox ready. \(VoxConfig.toggleChord)で開始 / 確定、\(VoxConfig.paletteChord)でパレット、escで破棄。"
          + "metrics=\(writer.displayPath) history=\(historyWriter.displayPath)")
      fflush(stdout)
    }
  }

  @objc func showSettings(_ sender: Any?) {
    settings.show()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard !isTerminating else { return false }
    guard !settingsOnly else {
      settings.show()
      return true
    }
    showSetup()
    return true
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    refreshSetupPermissions(retryHotkeys: true)
  }

  private func showSetup() {
    guard !isTerminating else { return }
    refreshSetupPermissions(retryHotkeys: true)
    appControlsWindow?.show()
  }

  private var inputPermissionsReady: Bool {
    AXIsProcessTrusted() && CGPreflightListenEventAccess() && CGPreflightPostEventAccess()
  }

  private func refreshSetupPermissions(retryHotkeys: Bool = false) {
    guard !settingsOnly, !isTerminating else { return }
    let snapshot = currentSetupPermissions()
    appControlsWindow?.updatePermissions(snapshot)
    guard controllerStarted, !permissionRequestInFlight, let controller else { return }
    let changed = snapshot != lastSetupPermissions
    lastSetupPermissions = snapshot
    if snapshot.isComplete {
      guard changed || retryHotkeys else { return }
      do {
        try controller.enableHotkeys()
        statusItemController?.update(phase: controller.residentPhase)
        appControlsWindow?.update(phase: controller.residentPhase)
      } catch {
        statusItemController?.update(phase: .error, detail: "ショートカットを登録できませんでした。Voxを開き直してください")
        appControlsWindow?.update(phase: .error, detail: "ショートカットを登録できませんでした。Voxを開き直してください")
      }
    } else if controller.residentPhase == .idle {
      controller.disableHotkeysWhenIdle()
      statusItemController?.update(phase: .permissionRequired)
      appControlsWindow?.update(phase: .permissionRequired)
    }
  }

  private func requestSetupPermission(_ permission: SetupPermission) {
    guard !isTerminating, !permissionRequestInFlight else { return }
    let snapshot = currentSetupPermissions()
    guard !snapshot.isGranted(permission) else {
      refreshSetupPermissions(retryHotkeys: true)
      return
    }
    permissionRequestInFlight = true
    statusItemController?.setPermissionRequestInFlight(true)
    appControlsWindow?.setPermissionRequestInFlight(true)
    Task { @MainActor in
      defer {
        self.permissionRequestInFlight = false
        self.statusItemController?.setPermissionRequestInFlight(false)
        self.appControlsWindow?.setPermissionRequestInFlight(false)
        self.refreshSetupPermissions(retryHotkeys: true)
      }
      guard !self.isTerminating else { return }
      switch permission {
      case .microphone:
        switch microphoneAuthorization() {
        case .notDetermined:
          _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied:
          openPermissionSettings(permission)
        case .authorized, .restricted, .unknown:
          break
        }
      case .accessibility:
        // Register this app as a requester, then take the user to its settings.
        // Never assume the request's return value means access was granted.
        if !AXIsProcessTrusted() {
          let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
          _ = AXIsProcessTrustedWithOptions(options)
        } else if !CGPreflightPostEventAccess() {
          _ = CGRequestPostEventAccess()
        }
        openPermissionSettings(permission)
      case .inputMonitoring:
        _ = CGRequestListenEventAccess()
        openPermissionSettings(permission)
      }
    }
  }

  private func openPermissionSettings(_ permission: SetupPermission) {
    let pane: String
    switch permission {
    case .microphone: pane = "Privacy_Microphone"
    case .accessibility: pane = "Privacy_Accessibility"
    case .inputMonitoring: pane = "Privacy_ListenEvent"
    }
    // Pane links are best effort; manual navigation remains visible in the checklist.
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane),
      NSWorkspace.shared.open(url) { return }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
  }

  private func requestPermissionsAndPerformPrimary(using controller: VoxController?) {
    guard let controller, controllerStarted, !isTerminating, !permissionRequestInFlight else { return }
    if ResidentPermissionPolicy.primaryAction(for: controller.residentPhase) == .performImmediately {
      _ = controller.performMenuPrimaryAction()
      return
    }
    guard currentSetupPermissions().isComplete else {
      showSetup()
      return
    }
    do {
      try controller.enableHotkeys()
    } catch {
      statusItemController?.update(phase: .error, detail: "ショートカットを登録できませんでした")
      appControlsWindow?.update(phase: .error, detail: "ショートカットを登録できませんでした")
      return
    }
    if !controller.performMenuPrimaryAction() {
      statusItemController?.update(phase: .error, detail: "貼り付け先のアプリを確認できませんでした")
      appControlsWindow?.update(phase: .error, detail: "貼り付け先のアプリを確認できませんでした")
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    Task { @MainActor in
      await controller?.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

func microphoneAuthorization() -> ResidentMicrophoneAuthorization {
  switch AVCaptureDevice.authorizationStatus(for: .audio) {
  case .authorized: .authorized
  case .notDetermined: .notDetermined
  case .denied: .denied
  case .restricted: .restricted
  @unknown default: .unknown
  }
}

func currentSetupPermissions() -> SetupPermissions {
  SetupPermissions(
    microphone: microphoneAuthorization(), accessibilityTrusted: AXIsProcessTrusted(),
    postEventAccess: CGPreflightPostEventAccess(), listenEventAccess: CGPreflightListenEventAccess())
}

/// ログイン項目からの起動は Apple Event で区別する（操作ウィンドウを出さない）。
func launchedAsLoginItem() -> Bool {
  guard let event = NSAppleEventManager.shared().currentAppleEvent,
    event.eventID == AEEventID(kAEOpenApplication)
  else { return false }
  return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
    == OSType(keyAELaunchedAsLogInItem)
}

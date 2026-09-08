import AppKit
import Foundation
import SwiftUI
import VoxCore

@MainActor
public final class SettingsController: NSObject, NSWindowDelegate {
  public static let changedNotification = Notification.Name("local.vox.settings.changed")
  public static let openNotification = Notification.Name("local.vox.settings.open")
  public static let openedNotification = Notification.Name("local.vox.settings.opened")
  public var onConfigurationChange: ((HotkeyConfiguration) -> Void)?
  public var onClose: (() -> Void)?
  public var activeConfiguration: HotkeyConfiguration { runtime.active }
  public private(set) var autoEnterEnabled: Bool
  public private(set) var autoEnterUnverified: Bool
  public private(set) var voiceProcessingEnabled: Bool
  public var isKeyWindow: Bool { panel?.isKeyWindow == true }
  private let store: SettingsStore
  private let defaults: HotkeyConfiguration
  private let overrides: HotkeyOverrides
  private var runtime: HotkeyRuntime
  private var presentation = SettingsPresentationState()
  private var panel: NSPanel?
  private var model: SettingsModel?

  public init(
    store: SettingsStore = .standard, defaults: HotkeyConfiguration,
    overrides: HotkeyOverrides = .init(), configuration: HotkeyConfiguration
  ) {
    self.store = store
    self.defaults = defaults
    self.overrides = overrides
    runtime = HotkeyRuntime(configuration: configuration)
    let saved = try? store.load()
    autoEnterEnabled = saved?.autoEnterEnabled ?? false
    autoEnterUnverified = saved?.autoEnterUnverified ?? false
    voiceProcessingEnabled = saved?.voiceProcessingEnabled ?? false
    super.init()
  }

  public func listen() {
    let center = DistributedNotificationCenter.default()
    center.addObserver(
      self, selector: #selector(settingsChanged), name: Self.changedNotification, object: nil)
    center.addObserver(
      self, selector: #selector(openRequested(_:)), name: Self.openNotification, object: nil)
  }

  @objc private func settingsChanged() { reload() }

  @objc private func openRequested(_ notification: Notification) {
    guard let request = notification.object as? String else { return }
    // A running instance owns the window, so its event tap can pass shortcut recording through.
    show()
    DistributedNotificationCenter.default().postNotificationName(
      Self.openedNotification, object: request, userInfo: nil, deliverImmediately: true)
  }

  public func reload() {
    do {
      let saved = try store.load()
      let next = try saved.resolved(defaults: defaults, overrides: overrides)
      runtime.update(next)
      autoEnterEnabled = saved.autoEnterEnabled
      autoEnterUnverified = saved.autoEnterUnverified
      voiceProcessingEnabled = saved.voiceProcessingEnabled
      onConfigurationChange?(runtime.active)
    } catch {
      // Keep a working finish key if a preferences file is malformed or temporarily unavailable.
      model?.errorMessage = error.localizedDescription
    }
  }

  public func beginSession() { runtime.beginSession() }

  public func endSession() {
    runtime.endSession()
    onConfigurationChange?(runtime.active)
  }

  public func transition(to phase: SettingsPresentationState.Phase) {
    let showPending = presentation.transition(to: phase)
    if phase == .finishing { hide() }
    if showPending { show() }
  }

  public func focusAfterClosing(paletteOpen: Bool, textEntryEnabled: Bool)
    -> SettingsPresentationState.FocusDestination {
    presentation.focusAfterClosing(paletteOpen: paletteOpen, textEntryEnabled: textEntryEnabled)
  }

  public func show() {
    // Keep ownership of distributed open requests while insertion is in flight.
    // openRequested still acknowledges them; the window is shown on returning to idle.
    guard presentation.requestShow() else { return }
    if panel == nil {
      let model = SettingsModel(
        store: store, defaults: defaults, overrides: overrides,
        microphoneProvider: MicrophoneDevices.snapshot)
      model.onSaved = { [weak self] in
        self?.reload()
        DistributedNotificationCenter.default().postNotificationName(
          Self.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
      }
      self.model = model
      model.refreshMicrophones()
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.title = "voxの設定"
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.level = .floating
      panel.delegate = self
      panel.contentView = NSHostingView(
        rootView: SettingsView(model: model) { [weak panel] in
          panel?.close()
        })
      panel.center()
      self.panel = panel
    } else if panel?.isVisible != true {
      model?.reload()
      model?.refreshMicrophones()
    }
    panel?.orderFrontRegardless()
    panel?.makeKey()
  }

  public func hide() {
    panel?.makeFirstResponder(nil)
    panel?.resignKey()
    panel?.orderOut(nil)
  }

  public func windowWillClose(_ notification: Notification) {
    onClose?()
  }
}

/// `Vox --settings` first asks a running instance. If absent, it opens only settings,
/// without registering event taps or requesting microphone/accessibility permissions.
@MainActor
final class SettingsLauncher: NSObject {
  private let controller: SettingsController
  private let request = UUID().uuidString
  private var acknowledged = false

  init(controller: SettingsController) { self.controller = controller }

  func open() {
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(didOpen(_:)),
      name: SettingsController.openedNotification, object: request)
    DistributedNotificationCenter.default().postNotificationName(
      SettingsController.openNotification, object: request, userInfo: nil, deliverImmediately: true)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard let self, !acknowledged else { return }
      controller.onClose = { NSApplication.shared.terminate(nil) }
      controller.show()
    }
  }

  @objc private func didOpen(_ notification: Notification) {
    acknowledged = true
    NSApplication.shared.terminate(nil)
  }
}

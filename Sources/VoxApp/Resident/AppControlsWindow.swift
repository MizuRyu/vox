import AppKit
import VoxCore

@MainActor
final class AppControlsWindow: NSObject, NSWindowDelegate {
  var onShowSettings: (() -> Void)?
  var onRequestPermission: ((SetupPermission) -> Void)?
  var onRefreshPermissions: ((_ userInitiated: Bool) -> Void)?
  var onQuit: (() -> Void)?

  private let window: NSWindow
  private let stateLabel = NSTextField(wrappingLabelWithString: "")
  private let completionLabel = NSTextField(labelWithString: "権限 0/3")
  private let progressIndicator = NSProgressIndicator()
  private let refreshButton = NSButton(title: "状態を再確認", target: nil, action: nil)
  private var rows: [SetupPermission: PermissionRowView] = [:]
  private var snapshot: SetupPermissions?
  private var permissionRequestInFlight = false
  private var refreshTimer: Timer?

  override init() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = "Vox"
    window.isReleasedWhenClosed = false
    window.delegate = self
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    window.setAccessibilityLabel("Vox build \(build) コントロール")

    let title = NSTextField(labelWithString: "Voxのセットアップ")
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    let introduction = NSTextField(wrappingLabelWithString:
      "音声入力には次の3つの権限が必要です。上から順に許可します。")
    introduction.textColor = .secondaryLabelColor
    completionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    completionLabel.textColor = .systemGreen

    progressIndicator.style = .bar
    progressIndicator.isIndeterminate = false
    progressIndicator.minValue = 0
    progressIndicator.maxValue = Double(SetupPermission.allCases.count)

    let permissionRows = SetupPermission.allCases.map { permission in
      let row = PermissionRowView(permission: permission)
      row.onRequest = { [weak self] permission in self?.onRequestPermission?(permission) }
      rows[permission] = row
      return row
    }
    let checklist = NSStackView(views: permissionRows)
    checklist.orientation = .vertical
    checklist.alignment = .leading
    checklist.spacing = 10
    for row in permissionRows {
      row.widthAnchor.constraint(equalTo: checklist.widthAnchor).isActive = true
    }

    stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
    stateLabel.setAccessibilityLabel("現在の状態")

    refreshButton.target = self
    refreshButton.action = #selector(refreshPermissionsManually)
    refreshButton.identifier = NSUserInterfaceItemIdentifier("refreshPermissions")
    let settingsButton = NSButton(title: "設定…", target: self, action: #selector(showSettings))
    settingsButton.keyEquivalent = ","
    settingsButton.keyEquivalentModifierMask = [.command]
    let closeButton = NSButton(title: "閉じる", target: self, action: #selector(close))
    closeButton.identifier = NSUserInterfaceItemIdentifier("close")
    let quitButton = NSButton(title: "Voxを終了", target: self, action: #selector(quit))
    quitButton.keyEquivalent = "q"
    quitButton.keyEquivalentModifierMask = [.command]
    quitButton.identifier = NSUserInterfaceItemIdentifier("quit")
    let buttons = NSStackView(views: [settingsButton, refreshButton, closeButton, quitButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8

    let footer = NSTextField(wrappingLabelWithString:
      "システム設定から戻ると状態が更新されます。変わらないときは「状態を再確認」を押してください。この画面を閉じてもVoxは動き続け、アプリを開き直すとまた表示できます。")
    footer.textColor = .secondaryLabelColor
    footer.font = .systemFont(ofSize: 12)

    let content = NSStackView(views: [
      title, introduction, completionLabel, progressIndicator, checklist, stateLabel, buttons, footer
    ])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 12
    content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    window.contentView = content
    for view in [introduction, progressIndicator, checklist, stateLabel, footer] {
      view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
    }
    update(phase: .idle)
    renderPermissions()
  }

  func show() {
    onRefreshPermissions?(true)
    startRefreshTimer()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
  }

  func update(phase: ResidentPhase, detail: String? = nil) {
    stateLabel.stringValue = "状態: \(detail ?? ResidentPresentation.statusTitle(for: phase))"
  }

  func updatePermissions(_ snapshot: SetupPermissions) {
    self.snapshot = snapshot
    renderPermissions()
  }

  func setPermissionRequestInFlight(_ inFlight: Bool) {
    permissionRequestInFlight = inFlight
    renderPermissions()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    stopRefreshTimer()
    sender.orderOut(nil)
    return false
  }

  private func renderPermissions() {
    let completed = snapshot?.completedCount ?? 0
    completionLabel.stringValue = "権限 \(completed)/\(SetupPermission.allCases.count)"
    progressIndicator.doubleValue = Double(completed)
    for permission in SetupPermission.allCases {
      rows[permission]?.render(snapshot: snapshot, requestInFlight: permissionRequestInFlight)
    }
    refreshButton.isEnabled = !permissionRequestInFlight
    refreshButton.title = permissionRequestInFlight ? "確認中…" : "状態を再確認"
  }

  private func startRefreshTimer() {
    stopRefreshTimer()
    let timer = Timer(timeInterval: 1, target: self, selector: #selector(pollPermissions),
      userInfo: nil, repeats: true)
    timer.tolerance = 0.15
    RunLoop.main.add(timer, forMode: .common)
    refreshTimer = timer
  }

  private func stopRefreshTimer() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  @objc private func showSettings() { onShowSettings?() }
  @objc private func refreshPermissionsManually() { onRefreshPermissions?(true) }
  @objc private func pollPermissions() { onRefreshPermissions?(false) }
  @objc private func quit() { onQuit?() }
  @objc private func close() { window.performClose(nil) }
}

@MainActor
private final class PermissionRowView: NSView {
  let permission: SetupPermission
  var onRequest: ((SetupPermission) -> Void)?
  private let marker = NSImageView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let actionButton = NSButton(title: "", target: nil, action: nil)

  init(permission: SetupPermission) {
    self.permission = permission
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    marker.translatesAutoresizingMaskIntoConstraints = false
    marker.imageScaling = .scaleProportionallyUpOrDown
    marker.imageAlignment = .alignCenter

    let title = NSTextField(labelWithString: Self.title(for: permission))
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    detail.font = .systemFont(ofSize: 12)
    detail.textColor = .secondaryLabelColor
    let labels = NSStackView(views: [title, detail])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 3

    actionButton.target = self
    actionButton.action = #selector(requestPermission)
    actionButton.identifier = NSUserInterfaceItemIdentifier("permission.\(permission.rawValue)")
    actionButton.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [marker, labels, actionButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 62),
      marker.widthAnchor.constraint(equalToConstant: 32),
      marker.heightAnchor.constraint(equalToConstant: 32),
      actionButton.widthAnchor.constraint(equalToConstant: 150),
      labels.widthAnchor.constraint(equalTo: widthAnchor, constant: -206),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) { nil }

  func render(snapshot: SetupPermissions?, requestInFlight: Bool) {
    let granted = snapshot?.isGranted(permission) == true
    let symbolName = granted ? "checkmark.circle.fill" : "\(permission.rawValue + 1).circle"
    marker.image = NSImage(systemSymbolName: symbolName,
      accessibilityDescription: granted ? "許可済み" : "手順 \(permission.rawValue + 1)")
    marker.symbolConfiguration = granted
      ? NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen])
      : NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    marker.contentTintColor = granted ? nil : .secondaryLabelColor
    marker.setAccessibilityLabel(granted ? "許可済み" : "手順 \(permission.rawValue + 1)")
    detail.stringValue = detailText(snapshot: snapshot, granted: granted)
    actionButton.title = actionTitle(snapshot: snapshot, granted: granted)
    actionButton.isEnabled = snapshot != nil && !granted && !requestInFlight
      && !isRestrictedOrUnknown(snapshot)
  }

  private func detailText(snapshot: SetupPermissions?, granted: Bool) -> String {
    if granted { return "許可済み" }
    guard let snapshot else { return "確認中" }
    if permission == .microphone {
      if snapshot.microphone == .restricted { return "管理者の制限で変更できません" }
      if snapshot.microphone == .unknown { return "マイクの権限を確認できません" }
    }
    switch permission {
    case .microphone: return "音声を文字にするために使います"
    case .accessibility: return "ショートカットと貼り付けに使います。macOSから再起動を求められたら、Voxを終了して開き直します。"
    case .inputMonitoring: return "どのアプリでもショートカットを受け取るために使います"
    }
  }

  private func actionTitle(snapshot: SetupPermissions?, granted: Bool) -> String {
    if granted { return "許可済み" }
    guard let snapshot else { return "確認中" }
    if permission == .microphone {
      switch snapshot.microphone {
      case .denied: return "システム設定を開く"
      case .restricted: return "管理者による制限"
      case .unknown: return "状態不明"
      default: break
      }
    }
    return "許可する"
  }

  private func isRestrictedOrUnknown(_ snapshot: SetupPermissions?) -> Bool {
    permission == .microphone
      && (snapshot?.microphone == .restricted || snapshot?.microphone == .unknown)
  }

  @objc private func requestPermission() { onRequest?(permission) }

  private static func title(for permission: SetupPermission) -> String {
    switch permission {
    case .microphone: "マイク"
    case .accessibility: "アクセシビリティ"
    case .inputMonitoring: "入力監視"
    }
  }
}

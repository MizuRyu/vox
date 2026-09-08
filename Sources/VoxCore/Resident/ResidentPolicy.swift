import Foundation

public enum ResidentPhase: Sendable, Equatable {
  case idle
  case starting
  case recording
  case finishing
  case permissionRequired
  case error
}

public enum ResidentPresentation {
  public static func statusTitle(for phase: ResidentPhase) -> String {
    switch phase {
    case .idle: "待機中"
    case .starting: "準備中"
    case .recording: "録音中"
    case .finishing: "確定中"
    case .permissionRequired: "権限の確認が必要"
    case .error: "エラー"
    }
  }

  public static func primaryActionTitle(for phase: ResidentPhase) -> String {
    switch phase {
    case .recording: "確定して貼り付け"
    case .permissionRequired: "権限を再確認"
    default: "録音を開始"
    }
  }

  public static func canToggleRecording(in phase: ResidentPhase) -> Bool {
    switch phase {
    case .idle, .recording, .permissionRequired, .error: true
    case .starting, .finishing: false
    }
  }
}

public enum ResidentTargetPolicy {
  public static func isEligible(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
    return bundleIdentifier != "local.vox.app"
      && bundleIdentifier.caseInsensitiveCompare("com.apple.systemuiserver") != .orderedSame
  }
}

public enum ResidentPaths {
  public static func defaultMetricsURL(applicationSupport: URL) -> URL {
    applicationSupport.appendingPathComponent("vox/metrics.jsonl")
  }
}

public enum ResidentLoginState: Sendable, Equatable {
  case disabled
  case enabled
  case requiresApproval
  case unavailable
}

public enum ResidentLoginAction: Sendable, Equatable {
  case register
  case unregister
  case openSystemSettings
  case none
}

public enum ResidentLoginPolicy {
  public static func action(for state: ResidentLoginState) -> ResidentLoginAction {
    switch state {
    case .disabled: .register
    case .enabled: .unregister
    case .requiresApproval: .openSystemSettings
    case .unavailable: .none
    }
  }
}

public enum ResidentMicrophoneAuthorization: Sendable, Equatable {
  case authorized
  case notDetermined
  case denied
  case restricted
  case unknown
}

public enum ResidentPrimaryAction: Sendable, Equatable {
  case performImmediately
  case checkPermissions
}

public enum ResidentPermissionPolicy {
  public static func allowsHotkeys(for authorization: ResidentMicrophoneAuthorization) -> Bool {
    authorization == .authorized || authorization == .notDetermined
  }

  public static func startupPhase(for authorization: ResidentMicrophoneAuthorization)
    -> ResidentPhase {
    switch authorization {
    case .authorized, .notDetermined: .idle
    case .denied, .restricted: .permissionRequired
    case .unknown: .error
    }
  }

  public static func primaryAction(for phase: ResidentPhase) -> ResidentPrimaryAction {
    phase == .recording ? .performImmediately : .checkPermissions
  }
}

public enum ResidentPalettePolicy {
  public static func allowsCurrentDirectoryFallback(isBundled: Bool) -> Bool {
    !isBundled
  }
}

public enum ResidentControlPresentationReason: Sendable, Equatable {
  case startup(isBundled: Bool, launchedAtLogin: Bool)
  case reopen
}

public enum ResidentControlPolicy {
  public static func shouldShowWindow(
    for reason: ResidentControlPresentationReason, permissionsReady: Bool
  ) -> Bool {
    switch reason {
    case .reopen:
      true
    case let .startup(isBundled, launchedAtLogin):
      isBundled && (!launchedAtLogin || !permissionsReady)
    }
  }

}

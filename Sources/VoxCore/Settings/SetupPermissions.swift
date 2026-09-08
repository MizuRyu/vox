public enum SetupPermission: Int, CaseIterable, Sendable {
  case microphone
  case accessibility
  case inputMonitoring
}

public struct SetupPermissions: Equatable, Sendable {
  public let microphone: ResidentMicrophoneAuthorization
  public let accessibilityTrusted: Bool
  public let postEventAccess: Bool
  public let listenEventAccess: Bool

  public init(
    microphone: ResidentMicrophoneAuthorization,
    accessibilityTrusted: Bool,
    postEventAccess: Bool,
    listenEventAccess: Bool
  ) {
    self.microphone = microphone
    self.accessibilityTrusted = accessibilityTrusted
    self.postEventAccess = postEventAccess
    self.listenEventAccess = listenEventAccess
  }

  public func isGranted(_ permission: SetupPermission) -> Bool {
    switch permission {
    case .microphone: microphone == .authorized
    case .accessibility: accessibilityTrusted && postEventAccess
    case .inputMonitoring: listenEventAccess
    }
  }

  public var completedCount: Int {
    SetupPermission.allCases.count(where: isGranted)
  }

  public var isComplete: Bool {
    completedCount == SetupPermission.allCases.count
  }
}

import ServiceManagement
import VoxCore

@MainActor
final class LoginItemService {
  typealias State = ResidentLoginState

  var state: State { Self.map(SMAppService.mainApp.status) }

  func register() throws { try SMAppService.mainApp.register() }

  func unregister() throws { try SMAppService.mainApp.unregister() }

  private static func map(_ status: SMAppService.Status) -> State {
    switch status {
    case .notRegistered: .disabled
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }
}

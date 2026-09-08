public enum SpeechAssetModuleStatus: Equatable, Sendable {
  case unsupported
  case supported
  case downloading
  case installed
  case unknown
}

public enum SpeechAssetReadiness {
  public static func isReady(
    localeIdentifier: String,
    installedLocaleIdentifiers: Set<String>,
    moduleStatus: SpeechAssetModuleStatus
  ) -> Bool {
    moduleStatus == .installed || installedLocaleIdentifiers.contains(localeIdentifier)
  }
}

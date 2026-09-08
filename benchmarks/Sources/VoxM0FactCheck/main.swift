import ApplicationServices
import Foundation
import M0HarnessCore
import Speech

@main
struct VoxM0FactCheck {
  static func main() async {
    let command = CommandLine.arguments.dropFirst().first ?? "speech"

    switch command {
    case "speech":
      await checkSpeech()
    case "events":
      checkEvents(arguments: Array(CommandLine.arguments.dropFirst(2)))
    default:
      fputs("usage: vox-m0-fact-check [speech|events]\n", stderr)
      Foundation.exit(64)
    }
  }

  private static func checkSpeech() async {
    let supported = await SpeechTranscriber.supportedLocales
    let installed = await SpeechTranscriber.installedLocales
    let supportedIDs = supported.map(localeID).sorted()
    let installedIDs = installed.map(localeID).sorted()
    let requested = Locale(identifier: "ja_JP")
    let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)

    print("speech_transcriber_available=\(SpeechTranscriber.isAvailable)")
    print("supported_locales=\(supportedIDs.joined(separator: ","))")
    print("installed_locales=\(installedIDs.joined(separator: ","))")
    print("ja_JP_supported=\(resolved != nil)")

    guard let locale = resolved else {
      print("ja_JP_installed=false")
      print("asset_status=unsupported")
      print("asset_installation_request_available=false")
      print("asset_installation_required_by_status=unavailable")
      print("asset_installation_decision_source=asset_status")
      return
    }

    let resolvedID = localeID(locale)
    let isInstalled = installedIDs.contains(resolvedID)
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: []
    )
    let modules: [any SpeechModule] = [transcriber]

    print("ja_JP_resolved_locale=\(resolvedID)")
    print("ja_JP_installed=\(isInstalled)")
    let assetStatus = await AssetInventory.status(forModules: modules)
    print("asset_status=\(assetStatus)")

    do {
      let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
      print("asset_installation_request_available=\(request != nil)")
      print("asset_installation_required_by_status=\(assetStatus.installationRequirement)")
      print("asset_installation_decision_source=asset_status")
    } catch {
      print("asset_installation_request_available=error")
      print("asset_installation_required_by_status=\(assetStatus.installationRequirement)")
      print("asset_installation_decision_source=asset_status")
      print("asset_error=\(String(reflecting: error))")
    }
  }

  private static func checkEvents(arguments: [String]) {
    let seconds = argumentValue("--seconds", in: arguments).flatMap(Double.init) ?? 10
    let requestPermissions = arguments.contains("--request-permissions")
    let postCommandV = arguments.contains("--post-command-v")
    if requestPermissions {
      _ = CGRequestListenEventAccess()
      _ = CGRequestPostEventAccess()
    }

    let state = EventProbeState()
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: mask,
      callback: { _, _, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let state = Unmanaged<EventProbeState>.fromOpaque(userInfo).takeUnretainedValue()
        state.accept(event)
        return Unmanaged.passUnretained(event)
      },
      userInfo: Unmanaged.passUnretained(state).toOpaque()
    )

    print("accessibility_trusted=\(AXIsProcessTrusted())")
    print("listen_event_access=\(CGPreflightListenEventAccess())")
    print("post_event_access=\(CGPreflightPostEventAccess())")
    print("event_tap_created=\(tap != nil)")
    guard let tap else {
      print("physical_command_shift_space_observed=false")
      print("synthetic_command_v_posted=false")
      print("synthetic_command_v_observed_by_tap=false")
      return
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    if postCommandV, CGPreflightPostEventAccess(),
      let eventSource = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: false) {
      down.flags = .maskCommand
      up.flags = .maskCommand
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      state.syntheticCommandVPosted = true
    }

    print("instruction=Press Command-Shift-Space within \(seconds) seconds")
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    print("physical_command_shift_space_observed=\(state.commandShiftSpaceObserved)")
    print("synthetic_command_v_posted=\(state.syntheticCommandVPosted)")
    print("synthetic_command_v_observed_by_tap=\(state.commandVObserved)")
    print("note=Tap observation confirms event routing, not that a target app consumed Paste.")
  }

  private static func argumentValue(_ option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func localeID(_ locale: Locale) -> String {
    locale.identifier(.bcp47)
  }
}

extension AssetInventory.Status {
  fileprivate var snapshot: AssetStatusSnapshot {
    switch self {
    case .unsupported: .unsupported
    case .supported: .supported
    case .downloading: .downloading
    case .installed: .installed
    @unknown default: .unknown
    }
  }

  fileprivate var installationRequirement: String {
    switch AssetInstallationPolicy.decision(for: snapshot) {
    case .ready: "false"
    case .install: "true"
    case .waitForDownload: "in_progress"
    case .unavailable: "unavailable"
    }
  }
}

private final class EventProbeState: @unchecked Sendable {
  private let lock = NSLock()
  private var _commandShiftSpaceObserved = false
  private var _commandVObserved = false
  private var _syntheticCommandVPosted = false

  var commandShiftSpaceObserved: Bool { lock.withLock { _commandShiftSpaceObserved } }
  var commandVObserved: Bool { lock.withLock { _commandVObserved } }
  var syntheticCommandVPosted: Bool {
    get { lock.withLock { _syntheticCommandVPosted } }
    set { lock.withLock { _syntheticCommandVPosted = newValue } }
  }

  func accept(_ event: CGEvent) {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    lock.withLock {
      if keyCode == 49, flags.contains(.maskCommand), flags.contains(.maskShift) {
        _commandShiftSpaceObserved = true
      }
      if keyCode == 9, flags.contains(.maskCommand) {
        _commandVObserved = true
      }
    }
  }
}

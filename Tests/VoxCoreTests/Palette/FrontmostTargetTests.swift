// T38-d / ADR-015 前面アプリからの検索対象。方式の選択、Zed の行の解釈、
// ps 出力から子孫 tty の列挙、tty の mtime 比較。

import Foundation
import Testing
import VoxCore

@Suite("Palette: 前面アプリからの検索対象")
struct FrontmostTargetTests {
  // MARK: 方式の選択

  @Test("The adapter table routes Orca, Zed and every terminal")
  func theAdapterTableRoutesOrcaZedAndEveryTerminal() throws {
    let expected: [String: PaletteTargetAdapter] = [
      "com.stablyai.orca": .orca,
      "dev.zed.Zed": .zed(channel: "stable"),
      "dev.zed.Zed-Preview": .zed(channel: "preview"),
      "dev.zed.Zed-Nightly": .zed(channel: "nightly"),
      "com.apple.Terminal": .terminal,
      "com.mitchellh.ghostty": .terminal,
      "com.cmuxterm.app": .terminal,
      "com.googlecode.iterm2": .terminal,
      "dev.warp.Warp-Stable": .terminal
    ]
    for (identifier, adapter) in expected {
      #expect(
        PaletteTargetAdapter.forBundleIdentifier(identifier) == adapter,
        "\(identifier) の方式が違う: \(PaletteTargetAdapter.forBundleIdentifier(identifier))")
    }
  }

  @Test("An unknown or missing bundle identifier has no adapter")
  func anUnknownOrMissingBundleIdentifierHasNoAdapter() throws {
    // 前方・後方一致で拾わない（ヘルパープロセスや別アプリを巻き込まない）。
    for identifier in [
      "com.apple.Safari", "", "dev.zed", "dev.zed.Zed.helper", "com.apple.Terminal.copy",
      "my.com.cmuxterm.app"
    ] {
      #expect(
        PaletteTargetAdapter.forBundleIdentifier(identifier) == PaletteTargetAdapter.none,
        "知らない bundle identifier に方式を割り当てた: \(identifier)")
    }
    #expect(PaletteTargetAdapter.forBundleIdentifier(nil) == PaletteTargetAdapter.none)
  }

  /// LaunchServices は同じアプリを `dev.warp.warp-stable` と `dev.warp.Warp-Stable` の
  /// 両方で持っている。表の引き当てで大文字小文字を見ない。
  @Test("The adapter table ignores the case of the bundle identifier")
  func theAdapterTableIgnoresTheCaseOfTheBundleIdentifier() throws {
    #expect(PaletteTargetAdapter.forBundleIdentifier("dev.warp.warp-stable") == .terminal)
    #expect(PaletteTargetAdapter.forBundleIdentifier("DEV.ZED.ZED") == .zed(channel: "stable"))
    #expect(PaletteTargetAdapter.forBundleIdentifier("COM.STABLYAI.ORCA") == .orca)
  }

  /// ヘッダの色を変えるのは「前面アプリから決まらなかった」回だけ（T23 の選び直しは通常表示）。
  @Test("Only Orca, Zed and terminals count as resolved from the frontmost app")
  func onlyOrcaZedAndTerminalsCountAsResolvedFromTheFrontmostApp() throws {
    let fromApp: [PaletteTargetSource] = [.orca, .zed, .terminal]
    let notFromApp: [PaletteTargetSource] = [.fallback, .worktree, .recent, .manual]
    for source in fromApp {
      #expect(source.resolvedFromFrontmostApp, "\(source.rawValue) が前面アプリ由来になっていない")
    }
    for source in notFromApp {
      #expect(!source.resolvedFromFrontmostApp, "\(source.rawValue) を前面アプリ由来にしている")
    }
  }

  // MARK: Zed の workspace DB の行

  @Test("The frontmost Zed window is the head of the session window stack")
  func theFrontmostZedWindowIsTheHeadOfTheSessionWindowStack() throws {
    // ウィンドウ id は 32bit に収まらない。
    #expect(ZedWorkspace.frontmostWindowID(sessionWindowStack: "[4294967297,4294967298]") == 4_294_967_297)
    #expect(ZedWorkspace.frontmostWindowID(sessionWindowStack: "[7]") == 7)
  }

  @Test("A missing or broken session window stack has no frontmost window")
  func aMissingOrBrokenSessionWindowStackHasNoFrontmostWindow() throws {
    for stack in ["", "[]", "[\"a\"]", "{\"0\":1}", "not json"] {
      #expect(
        ZedWorkspace.frontmostWindowID(sessionWindowStack: stack) == nil,
        "読めない焦点順からウィンドウ id を作った: \(stack)")
    }
  }

  @Test("The active workspace comes from the multi workspace state of that window")
  func theActiveWorkspaceComesFromTheMultiWorkspaceStateOfThatWindow() throws {
    let state = """
      {"active_workspace_id":57,"sidebar_open":false,"sidebar_state":"{\\"width\\":300.0}"}
      """
    #expect(ZedWorkspace.activeWorkspaceID(multiWorkspaceState: state) == 57)
  }

  @Test("A multi workspace state without an active workspace has no id")
  func aMultiWorkspaceStateWithoutAnActiveWorkspaceHasNoID() throws {
    for state in ["", "{}", "{\"sidebar_open\":true}", "{\"active_workspace_id\":null}", "[]"] {
      #expect(
        ZedWorkspace.activeWorkspaceID(multiWorkspaceState: state) == nil,
        "active_workspace_id の無い状態から id を作った: \(state)")
    }
  }

  @Test("A multi root workspace uses the first path")
  func aMultiRootWorkspaceUsesTheFirstPath() throws {
    #expect(ZedWorkspace.firstRoot(paths: "/Users/me/projects/vox") == "/Users/me/projects/vox")
    #expect(
      ZedWorkspace.firstRoot(paths: "/Users/me/projects/vox\n/Users/me/projects/other")
        == "/Users/me/projects/vox")
    // 先頭が空行・空白の行でも次の行に進む。
    #expect(
      ZedWorkspace.firstRoot(paths: "\n  \n/Users/me/projects/vox\n") == "/Users/me/projects/vox")
  }

  @Test("An empty or relative workspace path is not a target")
  func anEmptyOrRelativeWorkspacePathIsNotATarget() throws {
    for paths in ["", "\n\n", "projects/vox", "~/projects/vox"] {
      #expect(
        ZedWorkspace.firstRoot(paths: paths) == nil,
        "絶対パスでないものを検索対象にした: \(paths)")
    }
  }

  // MARK: ps 出力から子孫の tty

  /// cmux が `login` を起こし、その下に zsh が並ぶ実際の形。
  private let psOutput = """
      PID  PPID TTY      COMM
        1     0 ??       /sbin/launchd
      738     1 ??       /Applications/cmux.app/Contents/MacOS/cmux
     2016   738 ttys000  /usr/bin/login
     2053  2016 ttys000  -/bin/zsh
     2082  2053 ttys000  /bin/zsh
     2033   738 ttys001  /usr/bin/login
     2068  2033 ttys001  -/bin/zsh
      900     1 ??       /Applications/Other.app/Contents/MacOS/Other
     3001   900 ttys009  -/bin/zsh
    """

  @Test("Terminal devices come from every descendant of the frontmost app")
  func terminalDevicesComeFromEveryDescendantOfTheFrontmostApp() throws {
    let devices = ProcessTree.terminalDevices(fromPsOutput: psOutput, ofDescendantsOf: 738)
    #expect(devices == ["ttys000", "ttys001"], "子孫の tty を ps の順で 1 度ずつ返していない: \(devices)")
  }

  @Test("Terminal devices of another app are left out")
  func terminalDevicesOfAnotherAppAreLeftOut() throws {
    let devices = ProcessTree.terminalDevices(fromPsOutput: psOutput, ofDescendantsOf: 900)
    #expect(devices == ["ttys009"], "別のアプリの tty を混ぜた: \(devices)")
  }

  @Test("An app without a terminal descendant has no device")
  func anAppWithoutATerminalDescendantHasNoDevice() throws {
    #expect(
      ProcessTree.terminalDevices(fromPsOutput: psOutput, ofDescendantsOf: 1234).isEmpty,
      "子孫がいない PID から tty を作った")
    #expect(
      ProcessTree.terminalDevices(fromPsOutput: "", ofDescendantsOf: 738).isEmpty,
      "空の ps 出力から tty を作った")
    // 子孫がいても tty を持たないアプリ（ブラウザのヘルパー等）は対象外。
    let withoutTTY = """
        PID  PPID TTY      COMM
        400     1 ??       /Applications/Browser.app/Contents/MacOS/Browser
        401   400 ??       /Applications/Browser.app/Contents/MacOS/Helper
      """
    #expect(
      ProcessTree.terminalDevices(fromPsOutput: withoutTTY, ofDescendantsOf: 400).isEmpty,
      "tty を持たない子孫から tty を作った")
  }

  /// `ps` は走っている間にプロセスが消えるので、親が先に消えて ppid が自分を指す行が来ても止まらない。
  @Test("A process whose parent is itself does not loop")
  func aProcessWhoseParentIsItselfDoesNotLoop() throws {
    let output = """
        PID  PPID TTY      COMM
        500   500 ttys004  -/bin/zsh
        600   500 ttys005  -/bin/zsh
      """
    #expect(
      ProcessTree.terminalDevices(fromPsOutput: output, ofDescendantsOf: 500) == ["ttys005"],
      "自分を親に持つ行で自分自身を子孫に数えた")
  }

  // MARK: tty の mtime

  @Test("The most recently written device wins")
  func theMostRecentlyWrittenDeviceWins() throws {
    let devices = [
      TerminalDevice(name: "ttys000", modifiedAt: Date(timeIntervalSince1970: 100)),
      TerminalDevice(name: "ttys001", modifiedAt: Date(timeIntervalSince1970: 300)),
      TerminalDevice(name: "ttys002", modifiedAt: Date(timeIntervalSince1970: 200))
    ]
    #expect(TerminalDevice.mostRecentlyUsed(devices) == "ttys001", "mtime の新しい tty を選んでいない")
  }

  @Test("Devices written in the same second are picked by name")
  func devicesWrittenInTheSameSecondArePickedByName() throws {
    let devices = [
      TerminalDevice(name: "ttys003", modifiedAt: Date(timeIntervalSince1970: 100)),
      TerminalDevice(name: "ttys001", modifiedAt: Date(timeIntervalSince1970: 100))
    ]
    #expect(TerminalDevice.mostRecentlyUsed(devices) == "ttys001", "同じ時刻の tty の選び方が一定でない")
    #expect(TerminalDevice.mostRecentlyUsed([]) == nil, "tty が無いのに選んだ")
  }
}

import AppKit
import Combine
import Foundation
import VoxCore

@MainActor
public final class SettingsModel: ObservableObject {
  @Published public var toggleKey = ""
  @Published public var paletteKey = ""
  @Published public var autoEnterEnabled = false
  @Published public var autoEnterUnverified = false
  @Published public var voiceProcessingEnabled = false
  @Published public var microphoneInput: MicrophoneInput = .automatic
  @Published public var errorMessage: String?
  @Published public var savedMessage: String?
  @Published public private(set) var loadFailed = false
  @Published public private(set) var microphoneSnapshot: MicrophoneSnapshot = .unavailable
  @Published public private(set) var dictionaryMessage = ""
  /// 辞書の表の行（ADR-021）。nil は読めない辞書で、表からは書かない。
  @Published public private(set) var dictionaryRows: DictionaryRows?
  public let defaults: HotkeyConfiguration
  public let overrides: HotkeyOverrides
  public var onSaved: (() -> Void)?
  private let store: SettingsStore
  private let dictionary: DictionaryStore
  private let microphoneProvider: () -> MicrophoneSnapshot
  private var loadedData: Data?
  private var original = HotkeySettings()
  private var resetting = false
  /// 読んだときの中身。書く前に比べて、エディタでの変更を上書きしない。nil はファイルが無い回。
  private var dictionaryContents: String?

  public init(
    store: SettingsStore, defaults: HotkeyConfiguration, overrides: HotkeyOverrides = .init(),
    dictionary: DictionaryStore = .standard,
    microphoneProvider: @escaping () -> MicrophoneSnapshot = { .unavailable }
  ) {
    self.store = store
    self.defaults = defaults
    self.overrides = overrides
    self.dictionary = dictionary
    self.microphoneProvider = microphoneProvider
    reload()
  }

  public func refreshMicrophones() {
    microphoneSnapshot = microphoneProvider()
  }

  /// 件数と直すべき行番号を出す。壊れた行は表に出ないので、エディタで直してもらう（ADR-019）。
  public func refreshDictionary() {
    do {
      let contents = try dictionary.contents()
      dictionaryContents = contents
      let document = DictionaryDocument(contents: contents ?? "")
      if dictionaryRows == nil {
        dictionaryRows = DictionaryRows(document: document)
      } else {
        dictionaryRows?.reload(document)
      }
      guard let contents else {
        dictionaryMessage = "辞書ファイルはまだありません。"
        return
      }
      let table = DictionaryTable(contents: contents)
      dictionaryMessage = "\(table.entries.count)件を読み込みました。"
        + skippedNotice(table.skippedLines)
        + (dictionaryRows?.hasUnsavedEdits == true ? Self.unsavedNotice : "")
    } catch {
      dictionaryRows = nil
      dictionaryMessage = "辞書ファイルを読み込めません。ファイルを確認してから「更新」を押してください。"
    }
  }

  /// 表に出す値。ファイルの項目のあとに、左の列がまだ空の打ち込み途中の行が続く。
  public var dictionaryEntries: [DictionaryEntry] { dictionaryRows?.rows.map(\.entry) ?? [] }

  /// 空の行を表の末尾に足し（1 行まで）、その行の ID を返す。左の列が入るまでファイルには書かない。
  @discardableResult
  public func addDictionaryEntry() -> Int? {
    dictionaryRows?.addDraft()
  }

  /// セルの確定ごとに呼ぶ。保存できない値は画面に残し、ファイルは変えない。
  public func updateDictionaryEntry(id: Int, from: String, to: String) {
    let save: DictionaryRows.Save?
    do {
      save = try dictionaryRows?.edit(id, to: DictionaryEntry(from: from, to: to))
    } catch {
      if let message = Self.message(for: error) {
        dictionaryMessage = message
      } else if dictionaryRows?.hasUnsavedEdits == true {
        dictionaryMessage = Self.unsavedNotice
      }
      return
    }
    if let save { write(save) }
  }

  public func removeDictionaryEntry(id: Int) {
    guard let save = dictionaryRows?.remove(id) else {
      // 打ち込み途中の行を消しただけの回も、未保存の知らせを出し直す。
      refreshDictionary()
      return
    }
    write(save)
  }

  private static let unsavedNotice = "保存していない行があります。Enterを押すと保存し直します。"

  /// why: 左の列が空の追加行は打ち込み途中として黙って残す（ADR-021）。
  private static func message(for failure: DictionaryDocument.EditFailure) -> String? {
    switch failure {
    case .emptySource: nil
    case .duplicateSource(let source): "「\(source)」はすでにあります。"
    case .unrepresentable: "タブ・改行と、認識される表記の先頭の「#」は使えません。取り除いてください。"
    }
  }

  private func write(_ save: DictionaryRows.Save) {
    do {
      guard try dictionary.contents() == dictionaryContents else {
        refreshDictionary()
        dictionaryMessage = "辞書ファイルがほかで変更されていたため、読み込み直しました。もう一度編集してください。"
        return
      }
      try dictionary.save(save.document)
    } catch {
      dictionaryMessage = "辞書を保存できませんでした。辞書ファイルを開いて直してください。"
      return
    }
    dictionaryRows?.apply(save)
    refreshDictionary()
  }

  /// why: タブの代わりに空白で書いた回は落ちる行が全行になるので、先頭だけ挙げる。
  private func skippedNotice(_ lines: [Int]) -> String {
    guard !lines.isEmpty else { return "" }
    let shown = lines.prefix(5).map(String.init).joined(separator: "・")
    let rest = lines.count > 5 ? "ほか" : ""
    return "\(shown)行目\(rest)を読み込めませんでした。"
      + "1行に「認識される表記」とタブ、「入れたい表記」を書いてください。"
  }

  /// 無ければ書き方を書いたファイルを作ってから、利用者が使っているエディタに渡す。
  public func openDictionaryFile() {
    do {
      try dictionary.createIfMissing()
    } catch {
      dictionaryMessage = "辞書ファイルを作れません。保存先を確認してください。"
      return
    }
    NSWorkspace.shared.open(dictionary.url)
    refreshDictionary()
  }

  public func reload() {
    savedMessage = nil
    errorMessage = nil
    resetting = false
    do {
      loadedData = try store.contents()
      original = try store.decode(loadedData)
      loadFailed = false
    } catch {
      original = HotkeySettings()
      loadFailed = true
      // 設定画面からは直せないので、どのファイルをどうすれば直るかまで出す。
      errorMessage = """
        \(error.localizedDescription)
        \(store.url.path)
        このファイルを別名に退避してから「再読み込み」してください。
        """
    }
    toggleKey = original.toggleKey ?? defaults.toggle.spec
    paletteKey = original.paletteKey ?? defaults.palette.spec
    autoEnterEnabled = original.autoEnterEnabled
    autoEnterUnverified = original.autoEnterUnverified
    voiceProcessingEnabled = original.voiceProcessingEnabled
    microphoneInput = original.microphoneInput
  }

  public func resetDraft() {
    toggleKey = defaults.toggle.spec
    paletteKey = defaults.palette.spec
    autoEnterEnabled = false
    autoEnterUnverified = false
    voiceProcessingEnabled = false
    microphoneInput = .automatic
    resetting = true
    savedMessage = nil
  }

  @discardableResult
  public func save() -> Bool {
    guard !loadFailed else { return false }
    do {
      guard try store.contents() == loadedData else { throw HotkeySettingsError.changedOnDisk }
      var settings = HotkeySettings(
        toggleKey: resetting && toggleKey == defaults.toggle.spec ? nil : toggleKey,
        paletteKey: resetting && paletteKey == defaults.palette.spec ? nil : paletteKey,
        autoEnterEnabled: autoEnterEnabled,
        autoEnterUnverified: autoEnterUnverified,
        voiceProcessingEnabled: voiceProcessingEnabled, microphoneInput: microphoneInput)
      // A CLI override is not editable here and must never become a persisted preference.
      if overrides.toggle != nil { settings.toggleKey = original.toggleKey }
      if overrides.palette != nil { settings.paletteKey = original.paletteKey }
      // Preferences must also work on the next launch without temporary CLI overrides.
      _ = try settings.resolved(defaults: defaults)
      _ = try settings.resolved(defaults: defaults, overrides: overrides)
      try store.save(settings)
      reload()
      savedMessage = "保存しました。次の録音から反映されます。"
      onSaved?()
      return true
    } catch {
      errorMessage = error.localizedDescription
      savedMessage = nil
      return false
    }
  }
}

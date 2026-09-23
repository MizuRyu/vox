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
  /// 表に出す行。ファイルの項目のあとに、左の列がまだ空の打ち込み途中の行が続く（ADR-021）。
  @Published public private(set) var dictionaryEntries: [DictionaryEntry] = []
  public let defaults: HotkeyConfiguration
  public let overrides: HotkeyOverrides
  public var onSaved: (() -> Void)?
  private let store: SettingsStore
  private let dictionary: DictionaryStore
  private let microphoneProvider: () -> MicrophoneSnapshot
  private var loadedData: Data?
  private var original = HotkeySettings()
  private var resetting = false
  /// nil は読めない辞書。表からは書かない（読めないファイルを表の内容で上書きしない）。
  private var dictionaryDocument: DictionaryDocument?
  /// 読んだときの中身。書く前に比べて、エディタでの変更を上書きしない。nil はファイルが無い回。
  private var dictionaryContents: String?
  /// 「追加」で足した、左の列がまだ空の行。画面にだけあり、1 行に限る。
  private var dictionaryDraft: DictionaryEntry?

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
      dictionaryDocument = DictionaryDocument(contents: contents ?? "")
      publishDictionaryEntries()
      guard let contents else {
        dictionaryMessage = "辞書ファイルはまだありません。"
        return
      }
      let table = DictionaryTable(contents: contents)
      dictionaryMessage = "\(table.entries.count)件を読み込みました。"
        + skippedNotice(table.skippedLines)
    } catch {
      dictionaryDocument = nil
      dictionaryDraft = nil
      publishDictionaryEntries()
      dictionaryMessage = "辞書ファイルを読み込めません。ファイルを確認してから「更新」を押してください。"
    }
  }

  public var dictionaryEditable: Bool { dictionaryDocument != nil }

  /// 空の行を表の末尾に足す。左の列が入るまでファイルには書かない。
  public func addDictionaryEntry() {
    guard dictionaryDocument != nil, dictionaryDraft == nil else { return }
    dictionaryDraft = DictionaryEntry(from: "", to: "")
    publishDictionaryEntries()
  }

  /// セルの確定ごとに呼ぶ。保存できない行は画面に残し、ファイルは変えない。
  /// `original` はセルが表示していた行。行の削除などで位置がずれた後の遅れた確定を捨てるため。
  public func updateDictionaryEntry(
    at index: Int, replacing original: DictionaryEntry, from: String, to: String
  ) {
    guard var document = dictionaryDocument, dictionaryEntries.indices.contains(index),
      dictionaryEntries[index] == original
    else { return }
    let entry = DictionaryEntry(from: from, to: to)
    let isDraft = index == document.entries.count
    do {
      if isDraft {
        dictionaryDraft = entry
        try document.add(entry)
      } else {
        try document.update(at: index, entry: entry)
      }
    } catch {
      publishDictionaryEntries()
      if let message = Self.message(for: error) { dictionaryMessage = message }
      return
    }
    guard write(document) else { return }
    if isDraft { dictionaryDraft = nil }
    refreshDictionary()
  }

  public func removeDictionaryEntry(at index: Int) {
    guard var document = dictionaryDocument, dictionaryEntries.indices.contains(index) else { return }
    guard index < document.entries.count else {
      dictionaryDraft = nil
      publishDictionaryEntries()
      return
    }
    document.remove(at: index)
    guard write(document) else { return }
    refreshDictionary()
  }

  private func publishDictionaryEntries() {
    dictionaryEntries = (dictionaryDocument?.entries ?? []) + [dictionaryDraft].compactMap(\.self)
  }

  /// why: 左の列が空の行は打ち込み途中として黙って残す（ADR-021）。
  private static func message(for failure: DictionaryDocument.EditFailure) -> String? {
    switch failure {
    case .emptySource: nil
    case .duplicateSource(let source): "「\(source)」はすでにあります。"
    case .unrepresentable: "タブ・改行と、認識される表記の先頭の「#」は使えません。取り除いてください。"
    }
  }

  private func write(_ document: DictionaryDocument) -> Bool {
    do {
      guard try dictionary.contents() == dictionaryContents else {
        refreshDictionary()
        dictionaryMessage = "辞書ファイルがほかで変更されていたため、読み込み直しました。もう一度編集してください。"
        return false
      }
      try dictionary.save(document)
      return true
    } catch {
      dictionaryMessage = "辞書を保存できませんでした。辞書ファイルを開いて直してください。"
      return false
    }
  }

  /// why: タブの代わりに空白で書いた回は落ちる行が全行になるので、先頭だけ挙げる。
  private func skippedNotice(_ lines: [Int]) -> String {
    guard !lines.isEmpty else { return "" }
    let shown = lines.prefix(5).map(String.init).joined(separator: "・")
    let rest = lines.count > 5 ? "ほか" : ""
    return "\(shown)行目\(rest)を読み込めませんでした。"
      + "1行に「置き換える表記」とタブ、「入れたい表記」を書いてください。"
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

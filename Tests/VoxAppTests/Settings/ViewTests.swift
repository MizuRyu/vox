// 設定ビューはウィンドウも権限も要らずに組み立てられる。

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VoxApp
import VoxCore

@MainActor
@Suite("Settings: ビューの組み立て")
struct SettingsViewTests {
  @Test("settings view can be built without windows or permissions", arguments: [
    MicrophoneInput.automatic, .systemDefault, .device("synthetic-builtin"), .device("synthetic-missing")
  ])
  func settingsViewCanBeBuiltWithoutWindows(microphoneInput: MicrophoneInput) throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-settings-view-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
    try store.save(HotkeySettings(microphoneInput: microphoneInput))

    // 検査は 1 プロセスで走るので、他の検査が作った既存ウィンドウは許容し、新規生成だけを見る。
    let existingWindows = Set(application.windows.map(ObjectIdentifier.init))

    let model = SettingsModel(
      store: store, defaults: .standard,
      dictionary: DictionaryStore(url: root.appendingPathComponent("dictionary.tsv")),
      microphoneProvider: {
        .available(devices: [
          MicrophoneDevice(id: 1, name: "Synthetic Built-in", transport: .builtIn, uid: "synthetic-builtin")
        ], defaultDeviceID: 1)
      })
    model.refreshMicrophones()
    model.refreshDictionary()
    let view = NSHostingView(rootView: SettingsView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.width > 0 && view.fittingSize.height > 0, "empty settings view")
    let newWindows = Set(application.windows.map(ObjectIdentifier.init)).subtracting(existingWindows)
    #expect(newWindows.isEmpty, "settings inspection opened a window")
  }

  /// 辞書の状態はファイルの有無・件数・壊れた行で変わる。文言は content-guidelines に従う。
  @Test("設定画面は辞書の件数と直す行番号を出す")
  func settingsShowTheDictionaryState() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-dictionary-view-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let settings = SettingsStore(url: root.appendingPathComponent("settings.json"))
    let dictionary = DictionaryStore(url: root.appendingPathComponent("dictionary.tsv"))
    let model = SettingsModel(store: settings, defaults: .standard, dictionary: dictionary)

    model.refreshDictionary()
    #expect(model.dictionaryMessage == "辞書ファイルはまだありません。", "無い辞書の文言")

    try Data("松尾\t末尾\n".utf8).write(to: dictionary.url)
    model.refreshDictionary()
    #expect(model.dictionaryMessage == "1件を読み込みました。", "読み込めた辞書の文言")

    try Data("松尾\t末尾\n壊れた行\n".utf8).write(to: dictionary.url)
    model.refreshDictionary()
    #expect(model.dictionaryMessage.hasPrefix("1件を読み込みました。2行目を読み込めませんでした。"),
      "壊れた行の文言: \(model.dictionaryMessage)")

    // 全行がタブ無しの回（空白で書いた回）は行番号を並べ切らない。
    try Data(Array(repeating: "松尾 末尾", count: 8).joined(separator: "\n").utf8)
      .write(to: dictionary.url)
    model.refreshDictionary()
    #expect(model.dictionaryMessage.contains("1・2・3・4・5行目ほか"), "行番号の打ち切り")

    expectNoVisibleWindows()
  }

  // MARK: 辞書の表（ADR-021）

  /// 検査用の一時ディレクトリに辞書を置いた設定画面。ファイルのコメントと壊れた行は残る前提で見る。
  private func dictionaryFixture(_ contents: String) throws -> (root: URL, store: DictionaryStore, model: SettingsModel) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-dictionary-table-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = DictionaryStore(url: root.appendingPathComponent("dictionary.tsv"))
    try Data(contents.utf8).write(to: store.url)
    let model = SettingsModel(
      store: SettingsStore(url: root.appendingPathComponent("settings.json")), defaults: .standard,
      dictionary: store)
    model.refreshDictionary()
    return (root, store, model)
  }

  private let sample = "# 説明\n松尾\t末尾\n壊れた行\nオルカ\tOrca\n"

  @Test("辞書の表にファイルの項目が並ぶ")
  func theTableShowsTheEntries() throws {
    let (root, _, model) = try dictionaryFixture(sample)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(model.dictionaryEntries == [
      DictionaryEntry(from: "松尾", to: "末尾"), DictionaryEntry(from: "オルカ", to: "Orca")
    ])
    let view = NSHostingView(rootView: SettingsView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 520, height: 1400)
    view.layoutSubtreeIfNeeded()
    let table = try #require(firstTableView(in: view), "辞書の表が描かれていない")
    #expect(table.numberOfRows == 2, "表の行数")
    #expect(
      table.tableColumns.map(\.title) == ["認識される表記", "入れたい表記"], "列見出し")
    expectNoVisibleWindows()
  }

  @Test("「追加」の空行はファイルに書かず、左の列を入れると末尾に書く")
  func addingWritesTheEntryAtTheEnd() throws {
    let (root, store, model) = try dictionaryFixture(sample)
    defer { try? FileManager.default.removeItem(at: root) }

    model.addDictionaryEntry()
    model.addDictionaryEntry()
    #expect(model.dictionaryEntries.count == 3, "空行が表に出ない、または 2 行出た")
    #expect(try store.contents() == sample, "空行をファイルに書いた")

    model.updateDictionaryEntry(at: 2, replacing: model.dictionaryEntries[2], from: "", to: "バグ")
    #expect(model.dictionaryEntries.last == DictionaryEntry(from: "", to: "バグ"), "打ち込み途中の行が消えた")
    #expect(try store.contents() == sample, "左の列が空の行をファイルに書いた")

    model.updateDictionaryEntry(at: 2, replacing: model.dictionaryEntries[2], from: "ばぐ", to: "バグ")
    #expect(try store.contents() == sample + "ばぐ\tバグ\n", "追加した行")
    #expect(model.dictionaryEntries.last == DictionaryEntry(from: "ばぐ", to: "バグ"))
    #expect(model.dictionaryMessage.hasPrefix("3件を読み込みました。"), "\(model.dictionaryMessage)")
  }

  @Test("既にある表記は保存せず、打ち込んだ行を残して知らせる")
  func aDuplicateSourceIsReported() throws {
    let (root, store, model) = try dictionaryFixture(sample)
    defer { try? FileManager.default.removeItem(at: root) }

    model.addDictionaryEntry()
    model.updateDictionaryEntry(at: 2, replacing: model.dictionaryEntries[2], from: "松尾", to: "別")
    #expect(model.dictionaryMessage == "「松尾」はすでにあります。")
    #expect(model.dictionaryEntries.last == DictionaryEntry(from: "松尾", to: "別"), "打ち込んだ行が消えた")
    #expect(try store.contents() == sample, "重複をファイルに書いた")

    model.updateDictionaryEntry(at: 1, replacing: model.dictionaryEntries[1], from: "a\tb", to: "")
    #expect(model.dictionaryMessage == "タブ・改行と、認識される表記の先頭の「#」は使えません。取り除いてください。")
    #expect(try store.contents() == sample, "書けない表記をファイルに書いた")
  }

  @Test("「削除」はファイルから行を消し、コメントと壊れた行は残す")
  func removingDropsTheLineFromTheFile() throws {
    let (root, store, model) = try dictionaryFixture(sample)
    defer { try? FileManager.default.removeItem(at: root) }

    model.removeDictionaryEntry(at: 0)
    #expect(try store.contents() == "# 説明\n壊れた行\nオルカ\tOrca\n")
    #expect(model.dictionaryEntries == [DictionaryEntry(from: "オルカ", to: "Orca")])

    model.updateDictionaryEntry(at: 0, replacing: model.dictionaryEntries[0], from: "おるか", to: "Orca")
    #expect(try store.contents() == "# 説明\n壊れた行\nおるか\tOrca\n", "更新は元の位置")
  }

  /// 削除で行の位置がずれた後に、前の行のセルの確定が遅れて届いても別の行を書き換えない。
  @Test("位置がずれた後の遅れた確定は捨てる")
  func aStaleCommitIsIgnored() throws {
    let (root, store, model) = try dictionaryFixture(sample)
    defer { try? FileManager.default.removeItem(at: root) }
    let shown = model.dictionaryEntries[0]

    model.removeDictionaryEntry(at: 0)
    model.updateDictionaryEntry(at: 0, replacing: shown, from: "まつお", to: "末尾")
    #expect(try store.contents() == "# 説明\n壊れた行\nオルカ\tOrca\n", "ずれた行を書き換えた")
  }

  /// エディタで書き換えた内容を、表の古い内容で上書きしない。
  @Test("外で書き換えた辞書には書かず、読み直して知らせる")
  func anExternallyChangedDictionaryIsNotOverwritten() throws {
    let (root, store, model) = try dictionaryFixture(sample)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("松尾\t別\n".utf8).write(to: store.url)
    model.removeDictionaryEntry(at: 1)
    #expect(try store.contents() == "松尾\t別\n", "外の変更を上書きした")
    #expect(model.dictionaryEntries == [DictionaryEntry(from: "松尾", to: "別")], "読み直していない")
    #expect(model.dictionaryMessage == "辞書ファイルがほかで変更されていたため、読み込み直しました。もう一度編集してください。")
  }

  @Test("書けない辞書は保存できないと知らせる")
  func anUnwritableDictionaryIsReported() throws {
    let (root, store, model) = try dictionaryFixture(sample)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.linkItem(at: store.url, to: root.appendingPathComponent("hard"))
    model.removeDictionaryEntry(at: 0)
    #expect(model.dictionaryMessage == "辞書を保存できませんでした。辞書ファイルを開いて直してください。")
    #expect(try Data(contentsOf: store.url) == Data(sample.utf8), "書けない辞書を書き換えた")
  }

  private func firstTableView(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    return view.subviews.lazy.compactMap(firstTableView(in:)).first
  }
}

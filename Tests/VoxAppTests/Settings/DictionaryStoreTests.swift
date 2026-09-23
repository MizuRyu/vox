// 辞書ファイルの置き場と読み込み。形式の解釈は VoxCore の検査が持つので、ここは I/O だけを見る。
// 検査はそれぞれ自分の一時ディレクトリを使い、呼び出し側が消す。

import Foundation
import Testing
@testable import VoxApp
import VoxCore

@Suite("Settings: 辞書ファイル")
struct DictionaryStoreTests {
  /// 保存先だけを持つ使い捨ての辞書。root はまだ作らない（無い保存先も検査の対象）。
  private func fixture() -> (root: URL, store: DictionaryStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vox-dictionary-tests-\(UUID().uuidString)")
    return (root, DictionaryStore(url: root.appendingPathComponent("dictionary.tsv")))
  }

  @Test("無い辞書は読み込みを止めず、ファイルも作らない")
  func missingDictionaryIsEmpty() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try store.contents() == nil, "無いファイルが nil にならない")
    #expect(store.load().entries.isEmpty, "無い辞書が空にならない")
    #expect(!FileManager.default.fileExists(atPath: root.path), "読むだけでファイルを作った")
  }

  @Test("テンプレートは非公開で作られ、2 度目は書き足さない")
  func templateIsPrivateAndCreatedOnce() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }

    try store.createIfMissing()
    let mode =
      try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.intValue == 0o600, "辞書の権限")
    #expect(store.load().entries.isEmpty, "テンプレートに有効な行がある")
    #expect(store.load().skippedLines.isEmpty, "テンプレートに壊れた行がある")

    try Data("松尾\t末尾\n".utf8).write(to: store.url)
    try store.createIfMissing()
    #expect(
      try String(contentsOf: store.url, encoding: .utf8) == "松尾\t末尾\n",
      "既存の辞書にテンプレートを書き足した")
  }

  /// 案内どおり行頭の `#` だけを外したら、その行がそのまま効く（`# 松尾` の空白を残さない）。
  @Test("テンプレートの例は # を外すだけで効く")
  func uncommentingTheTemplateExampleWorks() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }

    try store.createIfMissing()
    let uncommented = try #require(try store.contents())
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.contains("\t") ? $0.dropFirst() : $0 }
      .joined(separator: "\n")
    try Data(uncommented.utf8).write(to: store.url)

    #expect(
      DictionaryPass.apply(to: "配列の松尾を取る", table: store.load()) == "配列の末尾を取る",
      "# を外した例が効かない")
    #expect(store.load().skippedLines.isEmpty, "# を外した例が壊れた行になった")
  }

  /// 読めないファイルを「作れません」で塞がない。開いて直せる状態のまま残す。
  @Test("読めない辞書があるときは作り直さず、そのまま残す")
  func anUnreadableDictionaryIsLeftForRepair() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let oversized = Data(repeating: 0x41, count: 64 * 1024 + 1)
    try oversized.write(to: store.url)

    try store.createIfMissing()
    #expect(try Data(contentsOf: store.url) == oversized, "読めない辞書を書き換えた")
  }

  @Test("書いた行が録音経路の辞書になる")
  func writtenLinesBecomeTheTable() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("# 説明\n松尾\t末尾\n壊れた行\n".utf8).write(to: store.url)

    #expect(store.load().entries == [DictionaryEntry(from: "松尾", to: "末尾")], "読んだ項目")
    #expect(store.load().skippedLines == [3], "落とした行番号")
  }

  @Test("上限を超える辞書と UTF-8 でない辞書は読めず、録音は辞書なしで続く")
  func oversizedAndInvalidDictionariesAreRefused() throws {
    let (root, store) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    try Data(repeating: 0x41, count: 64 * 1024 + 1).write(to: store.url)
    #expect(throws: (any Error).self) { _ = try store.contents() }
    #expect(store.load().entries.isEmpty, "上限超過で辞書が空にならない")

    try Data([0xFF, 0xFE, 0x41]).write(to: store.url)
    #expect(throws: (any Error).self) { _ = try store.contents() }
    #expect(store.load().entries.isEmpty, "UTF-8 でない辞書が空にならない")
  }

  @Test("symlink・hardlink・FIFO の辞書は読まない")
  func unsafeDictionaryTargetsAreRefused() throws {
    let (root, _) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    try expectRejectsUnsafeTargets(in: root) { url in
      _ = try DictionaryStore(url: url).contents()
    }
  }
}

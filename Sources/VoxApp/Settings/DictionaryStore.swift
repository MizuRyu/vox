import Foundation
import VoxCore

/// 辞書ファイルの場所と読み書き。形式の解釈は VoxCore（`DictionaryTable` / `DictionaryDocument`）。
/// 設定と同じ保存先に置き、同じ防御（通常ファイル・リンク数 1・所有者一致・上限）で読む。
public struct DictionaryStore: Sendable {
  /// why: 1 行ずつ足す表なので、設定ファイルと同じ 64KiB を上限にする。
  private static let maximumBytes = 64 * 1024

  public let url: URL
  public static var standard: Self {
    Self(url: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/vox/dictionary.tsv"))
  }

  public init(url: URL) { self.url = url }

  /// ファイルが無ければ nil。読めない（上限超過、UTF-8 でない、通常ファイルでない）なら投げる。
  func contents() throws -> String? {
    let data: Data
    do {
      data = try PrivateFileIO.read(url, maximumBytes: Self.maximumBytes)
    } catch PrivateFileSafetyError.systemCall(_, ENOENT) {
      return nil
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw DictionaryStoreError.invalidText
    }
    return text
  }

  /// why: 録音経路は辞書を読めなくても止めない。読めないことは設定画面が知らせる。
  func load() -> DictionaryTable {
    do {
      guard let contents = try contents() else { return .empty }
      return DictionaryTable(contents: contents)
    } catch {
      return .empty
    }
  }

  /// 設定画面の表の編集を書く（ADR-021）。読めない大きさの内容は書かない。
  func save(_ document: DictionaryDocument) throws {
    let data = Data(document.serialized.utf8)
    guard data.count <= Self.maximumBytes else { throw DictionaryStoreError.tooLarge }
    try PrivateFileIO.write(data, to: url)
  }

  /// 無ければ書き方だけを書いたファイルを作る。あるなら触らない。
  func createIfMissing() throws {
    do {
      guard try contents() == nil else { return }
    } catch {
      // why: 読めないファイルが既にある回。上書きせず、そのまま開いて直してもらう。
      return
    }
    try PrivateFileIO.append(Data(Self.template.utf8), to: url)
  }

  /// why: 例の行は `#` を外すだけで使える形にする（`# 松尾` の空白を残すと左辺が一致しない）。
  private static let template = """
    # vox の辞書。1 行に「置き換える表記」、タブ、「入れたい表記」を書きます。
    # # で始まる行と空行は無視します。右側を空にすると、その語を削除します。
    # 表計算アプリで開くと形式が変わることがあるので、テキストエディタで編集してください。
    # 例（行頭の # を外して使います）
    #松尾\t末尾
    #なんか、\t

    """
}

enum DictionaryStoreError: Error {
  case invalidText
  case tooLarge
}

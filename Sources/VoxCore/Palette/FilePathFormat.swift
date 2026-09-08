// T20。HUD の本文にファイルをペーストしたときのパスの形。
//
// 検索対象のリポジトリ（パレットが解決した `PaletteTarget.root`）の配下なら相対パス、
// 外ならホーム基準で `~` に短縮する。リポジトリが未解決（nil）なら短縮だけを掛ける。
// パレットが差し込むパスは相対パスなので、ペーストもそれに揃える。
//
// 実際の挿入（前後の空白）は `PaletteInsertion` に任せる。ここはパスの表記だけを決める。

import Foundation

public enum FilePathFormat {
  /// 1 つのパスの表記。`repositoryRoot` の配下なら root からの相対パス。
  public static func display(path: String, repositoryRoot: String?, homeDirectory: String)
    -> String {
    let standardized = standardize(path)
    if let root = repositoryRoot.map(standardize), !root.isEmpty {
      let prefix = root.hasSuffix("/") ? root : root + "/"
      if standardized.hasPrefix(prefix) {
        return String(standardized.dropFirst(prefix.count))
      }
    }
    let home = standardize(homeDirectory)
    guard !home.isEmpty, home != "/" else { return standardized }
    if standardized == home { return "~" }
    if standardized.hasPrefix(home + "/") {
      return "~/" + standardized.dropFirst(home.count + 1)
    }
    return standardized
  }

  /// 複数ファイルをまとめて 1 つの文字列にする（半角空白区切り）。空のパスは落とす。
  public static func insertion(paths: [String], repositoryRoot: String?, homeDirectory: String)
    -> String {
    paths
      .filter { !$0.isEmpty }
      .map { display(path: $0, repositoryRoot: repositoryRoot, homeDirectory: homeDirectory) }
      .joined(separator: " ")
  }

  /// 索引の列挙で使う相対化。`root` の配下でなければ nil。
  /// why: 文字数で切らない。`root` の末尾 `/` や `root` と前方一致する別ディレクトリでずれる。
  /// シンボリックリンクの解決は呼び出し側（列挙する前に root を実体にしておく）。
  public static func relative(path: String, root: String) -> String? {
    let base = root.hasSuffix("/") ? String(root.dropLast()) : root
    guard !base.isEmpty else { return nil }
    let prefix = base + "/"
    guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
    return String(path.dropFirst(prefix.count))
  }

  /// 末尾の `/` と `.` / `..` を畳む。`standardizingPath` は `~` の展開もするので
  /// ペーストされた `~` 付きのパスもここで絶対パスになる。
  private static func standardize(_ path: String) -> String {
    let standardized = (path as NSString).standardizingPath
    guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
    return String(standardized.dropLast())
  }
}

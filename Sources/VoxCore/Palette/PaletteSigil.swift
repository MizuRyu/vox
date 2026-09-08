// パレットの sigil（ADR-005）。v1 で実装するのは `@` だけだが、
// ソースを差し替えられる形にしておく（後から足すのが難しいのは実装ではなく指の記憶）。
//
// 検索フィールドの見た目は「sigil のチップ + 語」で、入力そのものは語だけを持つ。
// 空の語の先頭に sigil を打つと、その語ではなく sigil の切り替えとして解釈する。

import Foundation

public enum PaletteSigil: String, CaseIterable, Sendable {
  case file = "@"
  case symbol = "#"
  case command = "!"
  case branch = "~"

  public var label: String {
    switch self {
    case .file: "ファイル"
    case .symbol: "シンボル"
    case .command: "コマンド"
    case .branch: "ブランチ"
    }
  }

  /// v1 で実際に候補を出せるのは `@` だけ。他は凡例に「拡張」と出すためだけに存在する。
  public var isImplemented: Bool { self == .file }
}

public struct PaletteQuery: Equatable, Sendable {
  public let sigil: PaletteSigil
  public let term: String

  public init(sigil: PaletteSigil, term: String) {
    self.sigil = sigil
    self.term = term
  }
}

public enum PaletteQueryParser {
  /// `raw` の先頭が sigil ならソースの指定として食べる。無ければ `current` を維持する。
  public static func parse(_ raw: String, current: PaletteSigil = .file) -> PaletteQuery {
    guard let first = raw.first, let sigil = PaletteSigil(rawValue: String(first)) else {
      return PaletteQuery(sigil: current, term: raw)
    }
    return PaletteQuery(sigil: sigil, term: String(raw.dropFirst()))
  }
}

/// 差し込みの結果。オフセットはすべて UTF-16（NSTextView の NSRange に合わせる）。
public struct PaletteInsertionPlan: Equatable, Sendable {
  /// 差し込んだあとの全文。
  public let text: String
  /// 実際に差し込んだ文字列（前後の空白を含む）。
  public let inserted: String
  /// 差し込んだ位置。
  public let location: Int
  /// 差し込んだ直後の caret。
  public let caret: Int

  public init(text: String, inserted: String, location: Int, caret: Int) {
    self.text = text
    self.inserted = inserted
    self.location = location
    self.caret = caret
  }
}

public enum PaletteInsertion {
  /// 選択したパスを `committed` の `caret` 位置に差し込む（指示書「前後に半角空白を 1 つ」）。
  /// 隣が既に空白・改行・タブなら重ねない。先頭に差し込むときは前の空白を付けない。
  /// T13 で「末尾」から「指定位置」に一般化した（`@` を打った位置に入れるため）。
  public static func insert(_ value: String, into committed: String, at caret: Int)
    -> PaletteInsertionPlan {
    let text = committed as NSString
    let location = min(max(0, caret), text.length)
    guard !value.isEmpty else {
      return PaletteInsertionPlan(
        text: committed, inserted: "", location: location, caret: location)
    }
    let needsLeadingSpace = location > 0 && !isBoundary(text.character(at: location - 1))
    let needsTrailingSpace =
      location == text.length || !isBoundary(text.character(at: location))
    let inserted = (needsLeadingSpace ? " " : "") + value + (needsTrailingSpace ? " " : "")
    return PaletteInsertionPlan(
      text: text.replacingCharacters(in: NSRange(location: location, length: 0), with: inserted),
      inserted: inserted,
      location: location,
      caret: location + (inserted as NSString).length)
  }

  /// 空白として扱う文字（これに隣接するときは空白を重ねない）。
  private static func isBoundary(_ character: unichar) -> Bool {
    character == 0x20 || character == 0x0A || character == 0x09
  }

  /// 選択したパスを `committed` の末尾に足す。`insert` の末尾指定と同じ。
  public static func append(_ value: String, to committed: String) -> String {
    insert(value, into: committed, at: (committed as NSString).length).text
  }

  /// `⌥Enter`（ファイル名のみ）。
  public static func fileName(of path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}

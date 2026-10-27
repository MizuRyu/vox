// 日本語の文を単語に分け、読みをローマ字で返す（dictionary.py sessions が使う）。
// macOS の CFStringTokenizer を使うので、Python の標準ライブラリだけでは取れない漢字の読みも取れる。
// 入力: 1 行 = 1 文。出力: 単語ごとに「開始位置<TAB>長さ<TAB>読み」（UTF-16 単位）、文の終わりに空行。
import Foundation

let locale = Locale(identifier: "ja_JP") as CFLocale
while let line = readLine() {
  let text = line as NSString
  let tokenizer = CFStringTokenizerCreate(
    nil, text, CFRangeMake(0, text.length), kCFStringTokenizerUnitWord, locale)
  while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
    let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
    let reading = CFStringTokenizerCopyCurrentTokenAttribute(
      tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String ?? ""
    print("\(range.location)\t\(range.length)\t\(reading)")
  }
  print("")
}

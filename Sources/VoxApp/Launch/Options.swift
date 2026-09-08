// 起動引数の解釈。認識できない引数は usage を出して終了する（Startup 側で exit 64）。

import Foundation
import VoxCore

let directLaunchMetricsPath = "benchmarks/m1/metrics.jsonl"

struct VoxOptions {
  var metricsPath: String?
  var historyPath = HistoryStore.defaultPath
  var hotkeyOverrides = HotkeyOverrides()
  var settingsOnly = false
  var fallbackRepositories: [String] = []
  /// --print-history が指定されたときの件数。
  var printHistoryLimit: Int?
}

func usage() -> String {
  """
  usage: Vox [--metrics <path>] [--history <path>] [--toggle-key <chord>] [--palette-key <chord>]
             [--repo <path>]... [--no-filler-removal] [--no-edit-mode] [--no-sigil-trigger]
         Vox --print-history [n] [--history <path>]
         Vox --settings

    --settings           設定画面を開く（録音は開始しない）
    --metrics <path>      軸 A の計測 JSONL の出力先（CLI 既定 \(directLaunchMetricsPath)）
    --history <path>      確定テキストの履歴 JSONL（既定 \(HistoryStore.defaultPath)）
    --print-history [n]   履歴の末尾 n 件（既定 10）を出して終了する
    --log-text            確定テキストの全文を stderr に出す（既定オフ。発話内容が残るので注意）
    --no-filler-removal   フィラー除去（R18）を止める
    --no-edit-mode        HUD へのテキスト入力（R14）を止める。HUD を key window にしない
    --no-sigil-trigger    `@` の打鍵でパレットを開くのを止める（パレットは --palette-key だけになる）
    --toggle-key <chord>  録音の開始 / 確定のキー（既定 cmd+shift+space）
                          例: ctrl+k, opt+space, cmd+shift+space
                          修飾キー: cmd, shift, ctrl, opt。キー名: a-z, 0-9, space, tab, return, f1-f12, 記号
    --palette-key <chord> コマンドパレットのキー（既定 ctrl+p）。録音中のみ有効
    --repo <path>         パレットの検索対象が特定できないときのフォールバック（複数指定可）

  トグルキーで録音の開始 / 確定して挿入、パレットキーでファイルパレット、esc で破棄。終了は Ctrl-C。
  """
}

func parseOptions(_ arguments: [String]) -> VoxOptions? {
  var options = VoxOptions()
  var index = 0
  while index < arguments.count {
    if applyFlag(arguments[index], to: &options) {
      index += 1
      continue
    }
    guard
      let consumed = applyValuedOption(
        arguments[index], arguments: arguments, at: index, into: &options)
    else { return nil }
    index += consumed
  }
  return options
}

/// 引数を取らないフラグ。認識できなければ false を返してオプション側に回す。
private func applyFlag(_ argument: String, to options: inout VoxOptions) -> Bool {
  switch argument {
  case "--settings": options.settingsOnly = true
  case "--log-text": VoxConfig.logFinalText = true
  case "--no-filler-removal": VoxConfig.fillerRemovalEnabled = false
  case "--no-edit-mode": VoxConfig.textEntryEnabled = false
  case "--no-sigil-trigger": VoxConfig.sigilTriggerEnabled = false
  case "--help", "-h":
    print(usage())
    exit(0)
  default: return false
  }
  return true
}

/// 引数を取るオプション。消費した引数の数を返す。認識できない、または引数が足りなければ nil。
private func applyValuedOption(
  _ argument: String, arguments: [String], at index: Int, into options: inout VoxOptions
) -> Int? {
  if argument == "--print-history" {
    // 件数は省略できる（既定 10）。次の引数が数字のときだけ食べる。
    if index + 1 < arguments.count, let count = Int(arguments[index + 1]) {
      options.printHistoryLimit = count
      return 2
    }
    options.printHistoryLimit = 10
    return 1
  }
  guard index + 1 < arguments.count else { return nil }
  let value = arguments[index + 1]
  switch argument {
  case "--metrics": options.metricsPath = value
  case "--history": options.historyPath = value
  case "--toggle-key":
    guard let chord = validatedChord(value) else { return nil }
    options.hotkeyOverrides.toggle = chord
  case "--palette-key":
    guard let chord = validatedChord(value) else { return nil }
    options.hotkeyOverrides.palette = chord
  case "--repo": options.fallbackRepositories.append(value)
  default: return nil
  }
  return 2
}

private func validatedChord(_ value: String) -> String? {
  do {
    _ = try KeyChord.parse(value)
    return value
  } catch {
    voxWrite(Data("\(error)\n".utf8), to: .standardError)
    return nil
  }
}

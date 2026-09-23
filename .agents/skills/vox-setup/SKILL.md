---
name: vox-setup
description: >
  vox（macOS 日本語音声入力 HUD）のインストール・設定変更・ショートカット変更・
  トラブルシュートを頼まれたときに使う。ビルドと配置、settings.json の全フィールド、
  ショートカットの表記、権限、データの保存先とリセット方法を網羅している。
---

# vox セットアップ・運用スキル

## 担当範囲

この skill が持つ: 手元の導入・更新、権限、`settings.json`、ショートカット、起動引数、リセット、トラブルの切り分け。
渡す: Release を作る・タグを打つ・dmg を配る作業は `vox-release`。挙動を変える実装は本 skill の範囲外（設定の意味を説明するだけ）。

## 事前条件

- `just bundle` / `just install` は `nix develop` の中で実行する（`just` と SwiftLint は devShell にある）
- 更新の前に Vox を終了している（`just install` は起動中なら中断する）

## プロジェクト概要

- **スタック**: Swift 6.2 / SwiftPM、AppKit + SwiftUI、macOS 26 以上・Apple Silicon
- **役割**: 話した内容をローカルの `SpeechTranscriber` で認識し、HUD で編集して元のアプリへ貼り付ける
- **構成**: `Sources/Vox`（本体）、`Sources/VoxCore`（UI 非依存の判定）、`Sources/VoxSettingsSupport`（設定画面と保存）
- エージェントは Vox 本体を起動しない（`AGENTS.md`）。確認は利用者が行う

## インストール・更新

```sh
just bundle      # dist/Vox-<VERSION>.app と .dmg を作る（署名は下記）
just install     # /Applications/Vox.app に配置し quarantine を外す
```

更新時は先に Vox を終了する（Dock またはメニューバー →「Voxを終了」）。`just uninstall` で `/Applications/Vox.app` を消す。

### 署名と権限の関係

macOS はコード署名の要件でアプリの同一性を判定する。署名 identity が変わるとアクセシビリティ・入力監視の許可が無効になる。

| 署名 | 条件 | 更新後の権限 |
|---|---|---|
| Apple Development（固定） | `~/.config/vox/development-signing-identity` に証明書の SHA-1 fingerprint を置く | 引き継げる |
| Developer ID | 環境変数 `VOX_SIGNING_IDENTITY` | 引き継げる（公開配布用） |
| ad-hoc | どちらもない | **毎回許可し直し** |

## 初回の権限

`Vox.app` を開くとセットアップ画面が出て、マイク → アクセシビリティ → 入力監視の順に許可する。反映されないときは「状態を再確認」。
macOS が再起動を求めたら Vox を終了して開き直す。ソースから直接起動した場合（`swift run Vox`）は起動元ターミナルに同じ権限が要る。

## 設定ファイル

```
~/Library/Application Support/vox/settings.json   ← 設定（0600）
~/Library/Application Support/vox/history.jsonl   ← 確定本文の履歴（0600）
~/Library/Application Support/vox/folders.json   ← 最近使った検索フォルダ（0600、最大 20 件）
```

### settings.json フィールド一覧（`Sources/VoxCore/HotkeySettings.swift`）

欠けたフィールドは既定値で補う。壊れている場合は原本を残したまま既定値で起動し、設定画面にエラーを出す。

| フィールド | 型 | 既定値 | 意味 |
|---|---|---|---|
| `schema_version` | int | `1` | 形式の版。新しい版のファイルは古い vox で開けない |
| `toggle_key` | string \| null | `null`（= `cmd+shift+space`） | 録音開始／確定して貼り付け |
| `palette_key` | string \| null | `null`（= `ctrl+p`） | ファイル検索パレット |
| `auto_enter_enabled` | bool | `false` | 貼り付け後に Enter を送る |
| `auto_enter_unverified` | bool | `false` | ターミナルなど、入力欄を読み返せないアプリでも Enter を送る。貼り付け 0.5 秒後、同じアプリ・ウィンドウなら送る。以前の「Enter の送り方」で「貼り付け後に送る」を選んでいた設定は、これをオンとして引き継ぐ |
| `voice_processing_enabled` | bool | `false` | Apple のエコー除去・ノイズ抑制（実験的。再生中の音楽が小さくなる場合がある） |
| `microphone_input` | object | `{"mode":"automatic"}` | Vox の入力選択。`automatic` は既定の入出力が Bluetooth 系・出力稼働中なら内蔵入力を優先し、なければ既定入力。`system_default` は常に準備時の既定入力。`device` は `uid` で機器を固定し、未接続なら開始エラー |

マイクの指定は設定画面「使用するマイク」で保存する。個別指定の形式は `{"mode":"device","uid":"機器のUID"}`。UID は機器の再接続で変わりうる AudioDeviceID と区別し、診断ログには出さない。古い設定に `microphone_input` がなければ「自動」になる。macOS 全体の既定入力・既定出力は変更しない。録音中の設定変更は次の録音から反映する。

### ショートカットの表記（`Sources/VoxCore/HotkeyBinding.swift`）

`+` 区切り。修飾は `cmd` / `command` / `⌘`、`shift` / `⇧`、`ctrl` / `control` / `⌃`、`opt` / `option` / `alt` / `⌥`。
⌘・⌃・⌥ のいずれかを含むか、`f1`〜`f12` 単独。録音とパレットに同じキーは不可。

### 既定のショートカット

| 操作 | 既定 |
|---|---|
| 録音開始／確定して貼り付け | `⌘⇧Space` |
| ファイル検索 | `⌃P`（HUD で `@` を入力しても開く） |
| 検索対象の候補を巡る | `⌘]`（パレット表示中。別 worktree → 最近使ったフォルダの順） |
| 設定を開く | `⌘,`（Vox にフォーカスがあるとき） |
| パレットを閉じる／本文を破棄 | `Esc`（フォルダ選択モードではファイル検索に戻る） |

### 優先順位

**起動引数（`--toggle-key`, `--palette-key`）→ settings.json → 既定値**。起動引数で固定したキーは、その起動中は設定画面で編集できない。

### 反映タイミング

| 変更方法 | 反映 |
|---|---|
| 設定画面（メニューバー「設定…」/ HUD の歯車 / `⌘,`）で保存 | 待機中なら即時、録音中なら次の録音から |
| `settings.json` を直接編集 | 次の起動、または設定画面の「再読み込み」 |

## 起動引数（`Sources/Vox/main.swift`）

| 引数 | 意味 |
|---|---|
| `--settings` | 録音を始めず設定画面だけ開く |
| `--toggle-key SPEC` / `--palette-key SPEC` | その起動中だけキーを固定 |
| `--repo PATH`（複数可） | Orca / Terminal から対象を決められないときの検索フォルダ |
| `--metrics PATH` / `--history PATH` | 計測・履歴の保存先 |
| `--print-history [N]` | 履歴の末尾 N 件（既定 10）を表示して終了 |
| `--log-text` | 診断ログに確定本文を出す（既定オフ） |
| `--no-filler-removal` / `--no-edit-mode` / `--no-sigil-trigger` | 各機能を無効化 |

## リセット

| 対象 | 操作 |
|---|---|
| 設定 | Vox を終了して `rm ~/Library/Application\ Support/vox/settings.json` |
| 履歴 | 同じく `history.jsonl` を削除 |
| 最近使った検索フォルダ | 同じく `folders.json` を削除（次の確定から溜まり直す）。常駐している索引も次の起動で空になる |
| 権限 | システム設定 → プライバシーとセキュリティ → アクセシビリティ / 入力監視 で Vox を削除して追加し直す |

## よくあるトラブル

- **指定したマイクが見つからない**: 接続後に設定の「更新」を押すか、「使用するマイク」を選び直して保存する。別のマイクへ自動的には戻さない
- **音楽が途切れる**: 「使用するマイク」を内蔵・USBなどへ指定して保存する。「自動」の切替は既定の入出力が Bluetooth 系かつ出力稼働中の場合だけ。「通話向けの音声処理」はオフにする。診断ログの `audio_input` が選択した機器、`audio_input_verified device_id= route=input_only` が開始後の機器確認を示す。録音直後に `audio_configuration_changed` が出る場合は録音が打ち切られている
- **貼り付けが起きない**: メニューバー「診断ログを開く…」で `error` を見る。意味は `docs/development.md` の表。`input_target_changed_*` は確定時に前面アプリが変わっている
- **Enter が省略される**: 修飾キーが押されたまま、入力先の変更、クリップボード競合で省略する。入力欄を読み返せないアプリ（ターミナル系）では `auto_enter_unverified` をオンにしないと送らない
- **更新したら権限が消えた**: 署名 identity の変更。上の「署名と権限の関係」
- **Orca でファイル検索の対象が違う**: Orca の画面でアクティブなローカル worktree を対象にする。一意に決まらなければ `--repo` の設定フォルダ。その場で変えるなら候補行の最近使ったフォルダ、またはヘッダのパスをクリックして「フォルダを選ぶ」。切り替えはその録音のあいだだけ有効で、固定はできない
- **最近使ったフォルダが出ない**: 記録はパレットからファイルを確定した回だけ。消えたフォルダは読み込みで落とす。溜まり直すには `folders.json` を消す
- **パレットの候補が古い／出るのが遅い**: 起動時に `folders.json` の Git 管理下フォルダ（新しい順に最大 20 件）の索引を常駐させ、FSEvents の通知（latency 0.5 秒でまとめて届く）で更新する。診断ログの `index_resident` が常駐した件数、`index_rebuilt` が読み直し（`scope=changes` は `git status` だけ、`scope=tracked` は `git ls-files` も）、`index_evicted` は上限（20 件 × 20,000 件）を超えて捨てたフォルダ、`index_watch_failed` は監視を始められず常駐させなかったフォルダ。捨てられたフォルダは開くたびの読み込みに戻る。Git 管理外のフォルダは常駐しない
- **メニューが見つからない**: `Vox.app` をもう一度開くとセットアップ画面が出る。ウィンドウを閉じても常駐は続く

## 開発コマンド早見表

| コマンド | 内容 |
|---|---|
| `just build` | release ビルド（起動しない） |
| `just test` | 回帰検査 |
| `just lint` | SwiftLint・ShellCheck・Python 構文 |
| `just check` | 秘密検査 + lint + フックの隔離検査 |
| `just verify` | check + build + test |
| `just bundle` / `just install` | .app / .dmg 生成と配置 |
| `swift run vox-doc-images` | README 用画像を合成データで再生成 |

## やらないこと

- Vox 本体を起動しない。権限ダイアログ、録音、貼り付けの確認は利用者が行う
- `settings.json` を利用者に断りなく書き換えない。値の意味を示し、利用者が編集するか設定画面で保存する
- システム設定の権限を script で操作しない（`tccutil` を含む）。手順を案内するだけ

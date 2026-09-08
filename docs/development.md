# 開発手順

コマンドはリポジトリのルートで実行します。

最終確認日: 2026-09-07

## 環境

- macOS 26 以降・Apple Silicon
- システムの Swift 6.2 以上（`Package.swift` の tools version は 6.2）
- 任意で `nix develop`：Python の評価環境、FFmpeg、just、Gitleaks、Semgrep、Lefthook、SwiftLint、ShellCheck などを用意する

Swift と Apple の SDK は Nix で管理しません。devShell でも `xcode-select` で選択した Xcode の SDK と Apple の `xcrun` を使います。`Tests/Tooling/nix-sdk-check.sh` で SDK 選択と manifest を検査できます。`.xcodeproj` も作りません（[ADR-006](adr/006-swiftpm-only-nix-devshell.md)）。本体の `Package.swift` は外部依存を持ちません。FluidAudio 0.15.0 に依存するのは M0 の比較ハーネスだけで、`benchmarks/Package.resolved` で固定しています。本体の認識は Apple を使います。

```sh
nix develop
just setup
just verify
```

`just setup` は現在の checkout に Lefthook を設置します。別の `core.hooksPath` や管理外の既存フックがある場合は上書きせず停止します。Lefthook 標準 launcher のツール欠落時の成功終了を避けるため、Lefthook を直接呼ぶフックを設置します。Lefthook がなければコミットを止めます。更新時も `just setup` を使ってください。

初回コミット前は flake が未追跡のため `nix develop path:.` を使います。コミット後は `nix develop` でも構いません。

## コマンド

| コマンド | 内容 |
|---|---|
| `just setup` | 開発ツールの確認と Lefthook の設置 |
| `just build` | 本体 `Vox` の release ビルド。起動しない |
| `just test` | 回帰検査一式 |
| `just lint` | SwiftLint・ShellCheck・Python の軽量な静的検査。ファイルは変更しない |
| `just check` | 秘密検査・静的検査・ツール自身の隔離テスト。ビルドと起動を含まない |
| `just verify` | `check` + `build` + `test` |
| `just bundle` | `dist/` に `.app` と `.dmg`（+ `.sha256`）を作る |
| `just install` / `just uninstall` | `/Applications/Vox.app` への配置と削除 |
| `just notarize IN OUT` | Apple へ送信して公証・stapling する明示操作 |
| `just bench-*` | M0 ベンチの実行・正規化・集計 |

FluidAudio は benchmarks の別 package だけが依存するので、本体は素の `swift build`（全ターゲット）で通ります。ベンチは `swift build --package-path benchmarks` です。

## 検査

各ターゲットは個別にも実行できます。

| コマンド | 対象 |
|---|---|
| `swift build --product Vox` | アプリ本体のビルド。起動しない |
| `swift test --no-parallel`（VoxCoreTests / VoxAppTests） | 文字順序・編集・フィラー・検索・直列化・送出手順（VoxCore）と、設定の保存・HUD の描画・pasteboard・パレットの再描画・常駐（VoxApp） |
| `swift test --no-parallel --filter 'StoreTests'` | 一部だけを走らせる例。`--filter` は型名・テスト名の正規表現 |

検査は Swift Testing の testTarget 2 本です（ADR-013）。`--no-parallel` を付けるのは、
並列だと実プロセスの取り消しを待つ 1 件と開いているウィンドウ数を見る 2 件（HUD の本文とパレットの再描画）が、
1 プロセスを共有する他の検査に干渉されて落ちるためです。
pasteboard とパレットの検査は API の意味を確かめるもので、他アプリへの実際の貼り付けまで
保証するものではありません。

## 静的解析と pre-commit

フックは `scripts/security --staged` と `scripts/lint --staged` を実行し、実際の index の内容を検査します。自動修正・自動 stage・Swift ビルド・モデル取得はしません。

| ツール | 検査範囲 |
|---|---|
| Gitleaks | 作業ツリー・index・存在する場合は全 Git 履歴の秘密候補 |
| Semgrep CE | リポジトリ内のローカルルール。Python の shell 実行、Swift の特定の危険パターン |
| 公開情報の補助検査 | 個人の絶対ユーザーパス。架空 fixture は区別する |
| SwiftLint | 重複 import、空コレクション判定、強制キャスト、強制 try |
| ShellCheck / Python | shell の静的検査、Python の構文検査 |

Swift 向け Semgrep ルールは generic パターンを使います。Swift AST・データフロー・依存関係の脆弱性を網羅する検査ではありません。リモートルール取得・ログインは不要で、metrics と version check は無効化します。解析エラーやツール失敗は不合格にします。

## ソースからの起動

```sh
swift run Vox
```

起動元のターミナルにマイク・アクセシビリティ・入力監視の権限が必要です。
**開発エージェントは本体を起動しません。** マイク・イベント監視・実キー送出の確認は利用者が行います。

`--repo /path/to/repository` で検索対象が自動解決できない場合のフォールバックを指定できます。録音・ファイル検索キーは HUD の歯車、または Vox にフォーカスがあるときの `⌘,` で変更できます。明示した `--toggle-key` / `--palette-key` は保存値より優先し、その起動中は画面で編集できません。キーや他のオプションは `Sources/VoxApp/Launch/Options.swift` の `usage()` にあります。

設定画面には macOS の既定入力マイクと入力デバイス一覧を表示します。開くたびと「更新」で取得し、録音中の engine が使う入力と同一とは断定しません。情報取得は CoreAudio の property 読取りだけで、マイク権限の要求や録音開始はしません。表示用の一覧は設定ファイルに保存しません。

## データの場所

| データ | 既定の保存先 |
|---|---|
| ホットキー設定 | `~/Library/Application Support/vox/settings.json`（schema 1、ファイル権限 0600） |
| 確定テキストの履歴 | `~/Library/Application Support/vox/history.jsonl` |
| アプリの計測 | `benchmarks/m1/metrics.jsonl`（Git 対象外） |
| M0 の音声・モデル・結果 | `benchmarks/m0/audio/`、`models/`、`results/`（Git 対象外） |

診断ログへの発話本文は既定オフです。`--log-text` を明示した場合だけ確定本文が残ります。履歴保存は別機能として継続します。履歴と計測ファイルは regular file・所有者・リンク数を検証して 0600 で開きます。既存の共有親ディレクトリの権限は変更しません。不要な履歴・ログは本体を停止してから該当ファイルを削除できます。

クリップボードの受領通知は第三者の読み取りでも立つため、履歴の `inserted` は受領通知だけでは true にしません。履歴の表示は末尾 1 MiB を上限にし、先頭の不完全行は除きます。省略があればその旨を表示し、全件数を推測しません。未検証の挿入は「挿入未確認」と表示します。軸 A は従来どおり受領通知までの値で、相手アプリの挿入・送信成功とは区別します。

設定が壊れている場合は原本を上書きせず既定値で起動します。設定画面に読み込みエラーが出る場合は、ファイルを修復または退避してから「再読み込み」してください。明示した CLI キーの衝突は通常起動を止めますが、`--settings` は開けます。

履歴・計測・診断ログの `error` は挿入が成立しなかった理由を同じ文字列で表します。空欄は成功です。

| `error` | 意味 |
|---|---|
| `start_failed` | 録音を開始できなかった。原因は診断ログの `start_error` 行に残る |
| `finalize_failed` | 認識の締めに失敗した。原因は診断ログの `finalize_error` 行に残る |
| `empty_text` | 確定時に本文が空で、貼り付けるものが無かった |
| `input_target_unknown` | 確定時に挿入先のアプリを特定できず、貼り付けを試みなかった |
| `injection_cancelled` | 挿入の処理が取り消された |
| `modifier_release_timeout` | 修飾キーが押されたままで、合成 Cmd+V が別の組み合わせになるため中止した |
| `input_target_changed_process` | 確定時の前面アプリが挿入先と違っていた |
| `input_target_changed_focus` | 挿入先アプリのフォーカス要素が開始時と入れ替わっていた |
| `input_target_changed_focus_unreadable` | 開始時は読めたフォーカス要素が確定時に読めなくなっていた |
| `paste_receipt_timeout` | Cmd+V を送ったが受領通知が来なかった。確定テキストはクリップボードに残る |
| `clipboard_changed` | 受領通知を待つ間に他のアプリがクリップボードを書き換えた |

`input_target_changed_*` の 3 つは診断ログの `injection_rejected` 行にも出ます。同じ行に確定時の前面アプリの bundle identifier と、開始時・確定時の AX role / subrole が付きます。本文・値・タイトルは読みません。

現在の計測は schema 5。`palette_resume_ms` は廃止し、パレット表示時間の `palette_open_ms` に変更しています。過去の JSONL には以前の schema が含まれるため、同じ意味の指標として混ぜないでください。

## 配布物と署名

`just bundle` は release executable をビルドし、Hardened Runtime とマイク入力 entitlement（`com.apple.security.device.audio-input` のみ。App Sandbox は使わない）を付けた `.app` と、`/Applications` へのショートカットを含む DMG、その SHA-256 を作ります。アイコンは `Resources/VoxIcon.png` を `sips` と `iconutil` で ICNS に変換したものです。

署名は環境で決まります。

| 状態 | 署名 | 用途 |
|---|---|---|
| `VOX_SIGNING_IDENTITY` あり | Developer ID Application | 公開配布。公証は `just notarize IN OUT`（`VOX_NOTARY_PROFILE` が必要。Apple へ送信する） |
| `~/.config/vox/development-signing-identity` に証明書の SHA-1 fingerprint | Apple Development（固定） | 手元の更新。権限を引き継げる |
| どちらもなし | ad-hoc | 診断用。更新のたびに権限を許可し直す必要がある |

**署名 identity を固定する理由**は、macOS が「以前許可したコード署名要件を更新版が満たすか」でアプリの同一性を判定するためです（[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)）。ad-hoc から開発用証明書、開発用から Developer ID へ移るとアクセシビリティ・入力監視の再許可が必要になります。開発用の署名は fingerprint だけを設定ファイルに置き、その証明書が現在の Keychain にない場合は失敗して別の証明書や ad-hoc へ切り替えません。証明書名・秘密鍵・notary profile の値はリポジトリにもコマンド引数にも書かず、環境変数から渡します。

`scripts/validate-app` は bundle identity、用途文言、最低 OS、arm64 Mach-O、コード署名、アイコン、予期しない symlink、個人ディレクトリの絶対パス混入を検査します。アプリ内の `BUILD-INFO.txt` には version、build number、Git revision、provenance、署名を除いて正規化した binary の SHA-256、対象 platform、作成時点の署名・ticket 状態を記録し、validator はこの digest と実際の payload の一致も確認します。dirty checkout の revision には `+dirty` が付きます。

## バージョンの目安

`VERSION` が唯一の版番号で、`CFBundleShortVersionString` と `CFBundleVersion` の両方に入ります。リリースごとに必ず変えます。

| 種別 | 内容 |
|---|---|
| patch | 不具合修正、見た目の調整 |
| minor | 新機能 |
| major | 互換破壊（設定ファイルや既定キーの非互換を含む） |

リリース手順は `.agents/skills/vox-release/SKILL.md` を参照してください。

## ベンチ

ベンチは `benchmarks/` の独立した package です（[ADR-013](adr/013-library-app-and-test-targets.md)）。FluidAudio に依存するのはここだけなので、`just verify` には含めず `just bench-test` で検査します。

```sh
just bench-run <engine> <manifest> <output>
just bench-test
```

Apple / Nemotron / Parakeet を比較します。入力形式は [manifest の例](../benchmarks/m0/manifest.example.tsv)、正解テキストの表記は [ADR-008](adr/008-reference-text-convention.md) を参照してください。`just bench-normalize` は音声の正規化、`just bench-jsut` は JSUT の取得、`just bench-report` は集計です。

集計の出力先は `benchmarks/m0/results/m0-results.md`（Git 対象外）。集計表だけで採用モデルを自動決定しません。M0 確定遅延とアプリの貼り付け遅延は別指標です。モデルの採用判断は [ADR-010](adr/010-speed-metric-axis-a-apple.md) と実発話による確認に基づきます。

README の画像を更新する場合は `swift run vox-doc-images` で合成データから再生成します。本体や録音を起動せず、個人の設定を読まずに描画します。

## コードの配置

| 場所 | 役割 |
|---|---|
| `Sources/Vox/` | 起動物。`main.swift` だけ |
| `Sources/VoxApp/` | macOS 層。録音セッション、音声入力、HUD、パレット、設定画面、常駐 UI、起動手順 |
| `Sources/VoxCore/` | UI に依存しない文字列・検索・履歴・計測のロジック |
| `Tests/` | 設定・コア・オフスクリーン検査・検査ツールのテスト |
| `scripts/` | ビルドと配布 |
| `benchmarks/` | M0 ベンチの別 package。ハーネス本体、検査、音声準備・データ取得・結果集計のスクリプト |

## 依存の更新

依存の更新 PR は [Renovate](https://docs.renovatebot.com/) が毎週月曜に作ります（設定は `renovate.json`）。対象は GitHub Actions、`flake.lock`、`benchmarks/Package.swift` の FluidAudio です。本体の `Package.swift` は外部依存を持ちません。CI はビルドを走らせないので、PR は手元で `just verify`（FluidAudio なら `just bench-test`）を通してからマージします。

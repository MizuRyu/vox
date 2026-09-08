# AGENTS.md

vox — macOS 専用の日本語音声入力 HUD（Swift 6.2 / SwiftPM、macOS 26+ / Apple Silicon）。
Apple `SpeechTranscriber` でローカル認識し、HUD で手入力・ファイルパス挿入を混ぜ、確定時に元のアプリへ貼り付ける。

## 仕様とガイドライン

- 現行仕様は `docs/specs/` が正。索引は `docs/README.md`
- 技術判断の理由と見直し条件は `docs/adr/`。判断をやり直す前に読む
- ディレクトリ構成と「どこに何を置くか」は `docs/specs/07-project-structure.md`。新しいファイルはその表に従って置く
- 利用者向けの操作・設定・制約は `docs/usage.md`
- アプリ内の文言（設定・HUD・通知・メニュー）は `docs/content-guidelines.md` の規約と用語集に従う
- ビルド・検査・データの保存先は `docs/development.md`
- インストール・設定ファイル・ショートカット・トラブルシュート: `.agents/skills/vox-setup/SKILL.md`
- リリース手順: `.agents/skills/vox-release/SKILL.md`（タグ = Release = dmg をワンセット、手書きノート）
- 変更後の docs 同期: `.agents/skills/vox-change-docs/SKILL.md`（specs / usage / setup スキルの 3 点）

## 処理の流れ（鍵になる型）

1. 録音キー（`HotkeyMonitor`、CGEventTap）→ 前面アプリを固定し、`SpeechLane` が `SpeechAnalyzer` を起動。results Task は start より先に立てる
2. 認識結果は `TranscriptBuffer`（VoxCore）に時間順の 3 区画（確定 / 未確定 / 手入力）で入り、`HudPanel` が表示する。手入力はカーソル位置、音声は末尾
3. `⌃P` / `@` で `PalettePanel` が開く。対象は `PaletteTargetResolver`（Orca → `orca worktree ps`、Terminal.app → tty → cwd → git root、それ以外 → `--repo`）。索引は `FileIndexer` → `FileIndex`（VoxCore）
4. 録音キー再押下で確定。`FillerPass` が規則でフィラーを落とし、`Injector` が入力先を再確認（`InjectionSafety`）してから ⌘V で貼り付け、任意で `AutoEnter`
5. 履歴は `HistoryRecord`、計測は `MetricsRecord` として JSONL に書く。設定は `HotkeySettings` を `SettingsStore` が読み書きする
6. 常駐は `StatusItemController`（メニューバー）と `AppControlsWindow`（初回セットアップと権限チェックリスト）。接続点は `App.swift` の `VoxController`

## コマンド

```sh
nix develop      # just, SwiftLint, ShellCheck, Gitleaks, Semgrep, Lefthook を揃える（Swift は Xcode 側）
just setup       # Lefthook を入れる
just build       # release ビルド（起動しない）
just test        # 回帰検査（本体は起動しない）
just verify      # check + build + test（完了前に必ず通す）
just bundle      # .app / .dmg を dist/ に作る
just install     # /Applications へ配置
```

## 原則

- **Vox 本体をエージェントが起動しない。** HUD・CGEventTap・キー送出・前面アプリの調査は利用者の作業を妨げる。検証はビルド、単体検査、オフスクリーン検査まで。マイク・権限・実キー送出の確認は利用者が行う
- UI に依存しない判定は `VoxCore` に置き、本体と同じ実装を検査する
- 音声・HUD を触る前に `docs/specs/03-architecture.md` の「実装上の落とし穴」を読む
- fixture・画像・Issue に実際の発話、履歴、認証情報、個人のパス、他アプリの画面を入れない。合成テキストと架空のパスを使う
- 循環的複雑度は `.swiftlint.yml` の閾値（warning 15 / error 25）を全関数が満たす。早期 return、平坦な制御流、責務が 1 つの小さな関数を、入れ子の条件分岐より優先する。複雑な処理を意味のない小関数に機械的に割って数値だけ下げない。閾値を緩めない、`swiftlint:disable` を足さない。超過を分割で解消できない場合（網羅的な `switch` 等）は理由を書いて利用者判断に回す
- 整形、構造変更、挙動変更を同じ変更に混ぜない。構成の移行は ADR-013 の段階順（ベンチ分離 → ライブラリ化 → テスト統合）で、各段階で `just verify` を通す
- SwiftPM のみ。`.xcodeproj` を作らない。nix は周辺ツールとベンチ環境だけ（ADR 006）
- 一時的な作業（下書き、調査ダンプ、単発スクリプト）は `z-ai/` に置く。git 管理外

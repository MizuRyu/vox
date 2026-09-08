# Contributing

Vox は macOS 26 以降・Apple Silicon 向けの SwiftPM プロジェクトです。変更する前に [開発手順](docs/development.md) と [仕様](docs/specs/README.md) を確認してください。

## セットアップ

```sh
nix develop
just setup
just verify
```

`just verify` は静的検査・秘密検査・ビルド・回帰検査をまとめて実行します。個別のコマンドは [開発手順](docs/development.md#コマンド) にあります。

## 守ること

- 録音開始・手入力・ファイル検索・確定して元アプリへ貼り付ける既存の流れを保ってください。
- 不具合は再現する検査を先に追加し、成功条件と変更理由を記録してください。UI の実機確認とオフスクリーン検査を区別します。
- UI に依存しない判定は `VoxCore` へ置き、本体と同じ実装を検査します。
- 実際の発話、履歴、認証情報、個人のパス、他のアプリの画面を fixture・スクリーンショット・Issue に含めないでください。合成テキストと架空のパスを使います。
- pre-commit は Gitleaks・Semgrep のローカルルール・SwiftLint・ShellCheck を実行します。解析エラーやツール欠落は不合格です。フックは自動修正・自動ステージングをしません。
- エージェントによる作業では本体を起動せず、ビルド・単体検査・オフスクリーン検査を使います。マイク・イベント監視・実キー送出は利用者が確認します。

挙動を変えたら [docs/specs/](docs/specs/README.md) の該当仕様、利用者に見える変更なら [docs/usage.md](docs/usage.md) も更新してください。判断の理由が変わる場合は [docs/adr/](docs/adr/README.md) に追加します。

## 変更の説明に書くこと

問題、変更後の動作、実行した検査とその結果、残る制約。

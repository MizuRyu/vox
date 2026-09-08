# ドキュメント

「どのファイルが有効な仕様か」をここで一元管理します。

最終確認日: 2026-09-07

## 使う

| ファイル | 内容 |
|---|---|
| [../README.md](../README.md) | インストールと基本操作 |
| [usage.md](usage.md) | 詳しい操作、ファイル検索、設定、権限、データ保存、制約 |
| [../SECURITY.md](../SECURITY.md) | データの扱いと脆弱性の報告 |
| [MANUAL-VERIFICATION.md](MANUAL-VERIFICATION.md) | リリース前に利用者が実機で確認する手動確認の TC 一覧 |
| [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | 既知の制約・未解決の不具合・未実装の一覧 |

## 開発する

| ファイル | 内容 |
|---|---|
| [development.md](development.md) | 環境、コマンド、検査、データの場所、配布物と署名、バージョンの目安 |
| [content-guidelines.md](content-guidelines.md) | アプリ内文言の規約（トーン、表記、用語集） |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | 変更の進め方と守ること |
| [images/README.md](../images/README.md) | README の画面例の由来と再生成 |

リリース手順は `.agents/skills/vox-release/SKILL.md`、インストールと設定の早見表は `.agents/skills/vox-setup/SKILL.md` にあります。

## 仕様と判断

| ファイル | 内容 |
|---|---|
| [specs/README.md](specs/README.md) | 仕様の索引と、どこを更新するか |
| [specs/01-requirements.md](specs/01-requirements.md) | 要件、二段構成という設計の芯 |
| [specs/02-speech-engines.md](specs/02-speech-engines.md) | 採用エンジン、実測値、却下した候補 |
| [specs/03-architecture.md](specs/03-architecture.md) | プロセス構成、キー体系、テキスト契約、挿入 |
| [specs/04-command-palette.md](specs/04-command-palette.md) | パレット、sigil、検索対象の解決 |
| [specs/05-text-postprocessing.md](specs/05-text-postprocessing.md) | 辞書と訂正（未実装） |
| [specs/06-permissions-and-risks.md](specs/06-permissions-and-risks.md) | 権限と残っているリスク |
| [specs/07-project-structure.md](specs/07-project-structure.md) | 目標のディレクトリ構成と責務の線 |
| [specs/references.md](specs/references.md) | 出典 |
| [adr/README.md](adr/README.md) | 技術判断の理由と見直し条件（ADR 001〜013） |

- 挙動を変えたら [specs/](specs/README.md) の該当ファイル、利用者に見える変更なら [usage.md](usage.md)、開発コマンドを変えたら [development.md](development.md)。
- 「なぜそうしたか」が変わったら [adr/](adr/README.md) に追加する。既存の ADR は書き換えない。
- README は入口だけを持つ。詳細はここから参照し、説明を重複させない。
- `z-ai/` は git 管理外の作業フォルダで、同期の対象ではない。

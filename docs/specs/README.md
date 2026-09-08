# 仕様

Vox の現行仕様。「なぜそう決めたか」は [ADR](../adr/README.md)。実測の生データは公開リポジトリに含めていません（端末情報を含むため）。

最終確認日: 2026-09-07

| ファイル | 内容 | 状態 |
|---|---|---|
| [01-requirements.md](01-requirements.md) | 要件 R1〜R18、二段構成という設計の芯 | 一部が将来設計 |
| [02-speech-engines.md](02-speech-engines.md) | 採用エンジン、実測値、フォールバック、却下した候補 | 速報レーンは実装済み |
| [03-architecture.md](03-architecture.md) | プロセス構成、キー体系、テキスト契約、挿入、落とし穴 | 実装済み（RingBuffer と確定レーンを除く） |
| [04-command-palette.md](04-command-palette.md) | パレット、sigil、検索対象の解決、索引とプレビュー | 実装済み（`@` のみ） |
| [05-text-postprocessing.md](05-text-postprocessing.md) | 辞書と訂正 | 未実装（将来） |
| [06-permissions-and-risks.md](06-permissions-and-risks.md) | 3 つの権限、残っているリスク | 実装済み |
| [07-project-structure.md](07-project-structure.md) | 目標のディレクトリ構成、責務の線、現状との対応 | 目標（移行中） |
| [references.md](references.md) | モデル・SDK・参考実装・理論・ベンチの出典 | — |

## どこを更新するか

- **挙動を変えたら**、対応する spec を直す。担当領域は上の表のとおり。新しい領域なら `NN-<名前>.md` を足し、この索引と [docs/README.md](../README.md) に行を追加する。
- **「なぜそうしたか」が変わったら** ADR を追加する。既存の ADR は書き換えず、置換なら `置換 (→ NNN)` にする。
- **利用者に見える挙動**は [usage.md](../usage.md)、**開発コマンド**は [development.md](../development.md) にも反映する。
- 各ファイルの冒頭に `最終確認日` を置く。内容を確認したら日付を更新する。

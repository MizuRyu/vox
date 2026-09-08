---
name: vox-change-docs
description: >
  vox のコード変更後にドキュメント 3 点を同期する（docs/specs の該当仕様、docs/usage.md、
  vox-setup スキルの設定・ショートカット表）。機能追加・挙動変更・設定項目追加・
  ショートカット追加を実装した直後、および実装エージェントへの指示書に docs 同期を
  含めるときに使う。
---

# vox 変更後ドキュメント同期

仕様の正は `docs/specs/`（索引は `docs/README.md`）。判断の理由は `docs/adr/`。すべて日本語。
`z-ai/` は git 管理外なので同期対象ではない。

## 担当範囲

この skill が持つ: 実装後の docs 同期（specs / usage / vox-setup / MANUAL-VERIFICATION）と、その漏れの機械チェック。
渡す: 仕様そのものの決定は ADR と利用者。リリースノートは `vox-release`。

## 事前条件

- 同期対象の変更が `just verify` を通っている（動いていない挙動を docs に書かない）
- 変更が「なぜ」を伴うなら、先に ADR の追加を利用者と決めている

## 同期チェックリスト

### 1. docs/specs/ の該当仕様（常に）

| spec | 担当領域 |
|---|---|
| 01-requirements | 要件、二段構成の目的（書き換えを消す）、非目標 |
| 02-speech-engines | 採用モデル、比較候補、却下したもの |
| 03-architecture | プロセス構成、キー体系、テキスト契約、テキスト挿入、実装上の落とし穴 |
| 04-command-palette | パレット、sigil、対象フォルダの解決（Orca / Terminal / worktree 候補） |
| 05-text-postprocessing | フィラー除去、辞書、訂正 |
| 06-permissions-and-risks | 権限、データの扱い、リスク |
| 07-project-structure | ディレクトリ構成、責務の線、ファイルの置き場 |
| references | 出典（モデル、SDK、参考実装、理論、ベンチ） |

新しい領域なら `NN-<名前>.md` を新設し、`docs/specs/README.md` と `docs/README.md` の索引に行を追加する。
「なぜそうしたか」が変わったら ADR を追加する（既存 ADR を書き換えない。置換なら `置換 (→ NNN)`）。

### 1b. アプリ内文言（UI に出る文字列を足す・変えるとき）

`docs/content-guidelines.md` の用語集と表記（英数字の前後はスペースなし、ボタンは名詞形、エラーは原因 + 次の行動）に合わせる。新しい概念の語は用語集に行を足す。

### 2. docs/usage.md（利用者に見える挙動が変わったら）

起動・権限・録音と貼り付け・ショートカット・ファイル検索・設定・データ保存と制約、の各節に反映する。
既定値の変更はここと README の両方に書く。

### 3. vox-setup スキル（設定項目・ショートカット・保存先を変えたら）

`.agents/skills/vox-setup/SKILL.md` を更新:

- `settings.json` のフィールド追加 → 「settings.json フィールド一覧」表に行を追加（フィールド名 / 型 / 既定値 / 意味）
- ショートカットの既定変更 → 「既定のショートカット」表
- 保存先・ログ・トラブルシュートの挙動が変わったら該当節

### 4. MANUAL-VERIFICATION の TC（挙動が変わったら）

`docs/MANUAL-VERIFICATION.md` に追記。書式:

```markdown
### <PREFIX>-NN <タイトル>

| 項目 | 内容 |
|---|---|
| **前提** | ... |
| **手順** | ... |
| **期待結果** | ... |
```

- TC-ID は永続識別子（変更・再利用しない）。既存カテゴリ: SETUP / REC / PASTE / ENTER /
  PAL / SET / RES / DIST。新領域は新プレフィックスを起こす
- 自動テスト化済みの項目は「自動化済み: <テスト名>」と注記して手動対象から外す
- **バグ修正は「再発したら気づける TC」を必ず1つ追加する**

## 検証

同期漏れの機械チェック（新しいフィールド名やキー名で）:

```sh
rg -l "<新フィールド名>" Sources/VoxSettingsSupport docs/usage.md .agents/skills/vox-setup/SKILL.md
# → 3 か所すべてに現れること
```

README.md は入口だけを持つ（導入・基本操作・主要リンク）。利用者が日常で使う変更（新ショートカット等）なら README も更新する。
検査を追加・変更したら `docs/development.md` の検査コマンド表も更新する。

## やらないこと

- 既存 ADR の本文を書き換えない（置換は新しい ADR で）
- 過去の測定値や当時の検証結果を現在の事実として書き換えない
- `z-ai/` 配下（作業記録）を同期対象に含めない

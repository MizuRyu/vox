---
name: vox-release
description: >
  vox の新バージョンをリリースする（VERSION の bump → 手書きリリースノート →
  タグ・push → .app / dmg ビルド → GitHub Release → ローカル更新）。「vX.Y.Z 切って」
  「リリースして」「新バージョン出して」と頼まれたときに使う。patch / minor / major の
  判断にも使う。
---

# vox リリース手順

タグ・Release・dmg は常にワンセット。タグだけ打っても main に push しただけでも配布されない。

## 担当範囲

この skill が持つ: バージョン bump、リリースノート、タグ、Release 作成、`just install` によるローカル更新。
渡す: 手元の導入・設定ファイル・権限のトラブルは `vox-setup`。コード変更に伴う docs 同期は `vox-change-docs`（リリース前に済んでいること）。

## 事前条件

1. 作業ツリーがクリーン（未コミットは利用者に確認して先にコミット）
2. `docs/MANUAL-VERIFICATION.md` の該当 TC を利用者が確認済み。エージェントは Vox 本体を起動しない（`AGENTS.md`）
3. バージョンの目安: patch = 不具合修正・見た目、minor = 新機能、major = 互換破壊（設定ファイルや既定キーの非互換を含む）
4. `VERSION` が唯一の版番号（`CFBundleShortVersionString` と `CFBundleVersion` の両方）。リリースごとに必ず変える

## 手順

```sh
# 1. bump → コミット（英語 conventional commits）
#    VERSION を X.Y.Z に書き換える
git add VERSION
git commit -m "chore: bump version to X.Y.Z"

# 2. リリースノートを手書きして z-ai/ に置く（後述の規約）。--generate-notes は使わない
#    inline --notes は避け、必ず --notes-file を使う

# 3. 検証 → タグ → push
just verify
git tag -a vX.Y.Z -m "vox vX.Y.Z"
git push origin main vX.Y.Z

# 4. ビルドして Release 作成
just bundle                      # dist/Vox-X.Y.Z.app と dist/Vox-X.Y.Z.dmg（+ .sha256）
gh release create vX.Y.Z dist/Vox-X.Y.Z.dmg dist/Vox-X.Y.Z.dmg.sha256 \
  --title "vox vX.Y.Z" --notes-file z-ai/vox-vX.Y.Z-notes.md

# 5. 検証 + ローカル更新
gh release view --json tagName,assets -q '.tagName + " / " + (.assets[0].name)'
just install                     # 起動中なら「Vox を終了」→ 開き直しを案内
```

## 署名

`just bundle` の署名は環境変数で決まる。

| 状態 | 署名 | 用途 |
|---|---|---|
| `VOX_SIGNING_IDENTITY` あり | Developer ID Application（`scripts/sign-app`） | 公開配布。公証は `just notarize IN OUT`（`VOX_NOTARY_PROFILE` が必要、Apple へ送信する） |
| なし・開発証明書を登録済み（`~/.config/vox/development-signing-identity`） | Apple Development | 手元の更新。権限（アクセシビリティ / 入力監視）を引き継げる |
| どちらもなし | ad-hoc | 診断用。**更新のたびに権限を許可し直す必要がある** |

公開 Release の dmg は Developer ID + 公証が前提。未署名で出す場合はノートに「初回起動時に quarantine 解除が必要」と書く。
証明書名・秘密鍵・notary profile の値はコマンド引数やファイルに書かず、環境変数から渡す。

## リリースノートの規約

日本語・手書き（commit の羅列にしない）。構成:

- 一行サマリ
- `## 新機能`（あれば）: **機能名** — 利用者視点の説明
- `## 改善・修正`（あれば）: 症状ベース（「〜する問題を修正」）
- `## インストール / 更新`: curl 一行
  `curl -fsSL https://raw.githubusercontent.com/MizuRyu/vox/main/scripts/install.sh | bash`（更新時は先に Vox を終了）。権限の再許可が要る場合はその旨
- 末尾に「macOS 26 以降 / Apple Silicon 向け。」

## 落とし穴

- **`dist/` の古い候補**: 出力名は署名モードを含まない `dist/Vox-<VERSION>.app`。同じ版でも署名 identity が違う app があると 2 回目の `just bundle` は拒否される（理由はエラーに出る）。署名モードを変えるときは `dist/Vox-<VERSION>.app` と `.dmg` を先に消す
- **権限が消えた**: 署名 identity が変わると macOS は別アプリとして扱う。システム設定 → プライバシーとセキュリティ → アクセシビリティ / 入力監視 で Vox の項目を削除して登録し直す
- **push がブロックされた**: pre-push ゲート（`scripts/security --all` + `scripts/lint`）の失敗理由を読む。本物の検出なら直してから push
- `LICENSE` と `THIRD-PARTY-LICENSES.md` は dmg に同梱される。依存を増やしたら後者を更新する

---
name: vox-debug
description: >
  vox の不具合を切り分ける（貼り付かない、Enter が出ない、音が途切れる、パレットの対象が違う、
  HUD にキーが届かない、確定が遅い）。「動かない」「おかしい」「ログ見て」で使う。診断ログ・計測・
  履歴・設定の保存先と読み方、既知の問題との突き合わせ、Issue に貼る形を扱う。修正の実装は対象外
  （原因の仮説と再現手順を出すところまで）。
---

# vox 不具合の切り分け

## 担当範囲

この skill が持つ: 症状の分類、直近の録音のログと計測の読み取り、既知の問題との突き合わせ、
結論（設定 / 権限 / 既知の問題 / 未知）と Issue の雛形。
渡す: 設定値の意味と直し方は `vox-setup`、修正の実装は別の依頼（実装後の docs 同期は `vox-change-docs`）、辞書の中身は `vox-add-dictionary`。

## 事前条件

- **Vox を起動しない**（`AGENTS.md`）。再現は利用者に頼み、「再現したら教えてください」で止まる
- ログは本文とパスを既定で書かない。`--log-text` で起動した回だけ `final_text` 行に本文が入る。
  スクリプトは `path=` `root=` `inserted=` `text=` の値、`final_text` の本文、マイクの機器名、絶対パス（行末まで）、
  形式の違う行を `<redacted>` にし、他アプリの bundle identifier を `app-1` のような呼び名にする（1 回の実行の中で同じ名前）。
  どのアプリかが切り分けに要るときは、呼び名を示して利用者に種類（エディタ・ターミナル・ブラウザ）を聞く

## 手順

1. 症状を分類する: 貼り付かない / Enter が出ない / 音が途切れる / パレットの対象が違う / HUD にキーが届かない / 確定が遅い。
   どれでもなければ「その他」として同じ手順で進める
2. 保存先（`~/Library/Application Support/vox/`）。読むのは下の表の範囲だけ

   | ファイル | 中身 | 読み方 |
   |---|---|---|
   | `logs/vox.log` | 診断ログ（2MiB で切り詰め） | `voxlog.py` だけで読む |
   | `metrics.jsonl` | 1 入力 1 行の計測（`swift run` の回は `benchmarks/m1/metrics.jsonl`） | `voxlog.py summary` |
   | `history.jsonl` | 確定本文の履歴 | **開かない**。`error` の列が要るなら `jq -c '{error, inserted, target_app}'` で本文を落とす |
   | `settings.json` | 設定 | `jq 'del(.microphone_input.uid)'` で UID を落として読む |
   | `folders.json` / `dictionary.tsv` / `attachments/` | 検索フォルダ / 辞書 / 貼った画像 | パスと語が入るので中身は出さない。件数と有無だけ |

3. 直近の録音を読む。スクリプトは `python3 .agents/skills/vox-debug/scripts/voxlog.py`

   ```sh
   voxlog.py last [N]      # 直近 N 回（既定 1）の録音。result 行は 1 行にまとめる
   voxlog.py errors [N]    # 直近 N 回（既定 5）の error 名と *_error / *_failed / *_timeout の行
   voxlog.py summary [N]   # 直近 N 回（既定 20）の axis_a_ms・first_token_ms・pause_commit_count の中央値と最大、error と target_app の件数
   ```

   症状ごとに見る行（意味は `docs/development.md` の `error` 表と `vox-setup` の「よくあるトラブル」。ここに重複させない）

   | 症状 | 見る行 |
   |---|---|
   | 貼り付かない | `errors` の `error=`、`injection_rejected`、`target_activate`、`paste_posted` / `paste_receipt`、`clipboard_restore` |
   | Enter が出ない | `auto_enter result=`、`auto_enter_modifier_state`、設定の `auto_enter_enabled` / `auto_enter_unverified` |
   | 音が途切れる | `audio_input`、`audio_input_verified`、`audio_configuration_changed`（メニューの「音声の診断を記録」をオンにした回は `audio_capture_*`） |
   | パレットの対象が違う | `palette_target source=`（`root=` は伏せてある。`source` と計測の `palette_target_source` で判断） |
   | HUD にキーが届かない | `hud_key state=` / `since_key_ms=`、`hud_key_equivalent` |
   | 確定が遅い | `segment_finalized reason=`、`segment_finalize_timeout`、`summary` の `axis_a_ms` と `pause_commit_count` |

   権限は録音の外（起動時）の行にある: `rg -N '^permissions ' ~/Library/Application\ Support/vox/logs/vox.log | tail -n 1`
4. `docs/KNOWN-ISSUES.md` の表と突き合わせる（制約 / 未解決 / 未実装）
5. 結論を 4 つのどれかで書く
   - **設定**: `settings.json` の項目名と、設定画面での直し方（`vox-setup` の表）
   - **権限**: システム設定 → プライバシーとセキュリティ → マイク / アクセシビリティ / 入力監視。
     署名が変わった更新なら `vox-setup` の「署名と権限の関係」
   - **既知の問題**: `KNOWN-ISSUES.md` の該当行
   - **未知**: 再現手順、伏せたログの抜粋、`sw_vers -productVersion`、リポジトリの `VERSION`。Issue の雛形を出す

   ```markdown
   ## 症状
   <6 分類のどれか。何をしたら何が起きたか>
   ## 再現手順
   1. …
   ## 環境
   macOS <sw_vers> / vox <VERSION> / 入力先アプリの種類（エディタ・ターミナル・ブラウザ）
   ## ログ（voxlog.py で伏せた行）
   ```

   Issue に貼ってよいのは `voxlog.py` の出力だけ。**本文・パス・他アプリの情報を含めない**。
   `app-1` などの呼び名は、利用者に聞いた種類に置き換えてもよい（アプリ名は書かない）
6. 修正に進むときは `vox-change-docs` の規則どおり、`docs/MANUAL-VERIFICATION.md` に「再発したら気づける TC」を足す

## 検証

- 結論に、根拠にした行（伏せた後）と、その行が症状とどうつながるかを 1 行ずつ書く
- スクリプトの検査は `Tests/Tooling/voxlog-script-tests.sh`（`just tooling-test` に含まれる）

## やらないこと

- Vox を起動する、キーを送る、前面アプリを調べる（`osascript` を含む）
- `history.jsonl` の本文、`--log-text` の本文、パスを会話や Issue に出す
- 修正の実装。仮説と再現手順までで止め、実装は別の依頼として受ける

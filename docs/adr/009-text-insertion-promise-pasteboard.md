# ADR-009: 前面アプリへのテキスト挿入は promise pasteboard 方式

- 状態: **提案**（実装前。M1 で実測してから承認）
- 日付: 2026-09-01
- 関連: 設計書 §4「テキスト挿入」

## 文脈

確定テキストを前面アプリに入れる方法は、業界がクリップボード + 合成 `Cmd+V` に収束している。
しかし**クリップボード復元のタイミングが全実装共通の地雷**で、固定 sleep の値が実装ごとにばらけている。

| 実装 | 復元待ち |
|---|---:|
| Whispering | 0.1s |
| VoiceInk | 0.25s |
| OpenWhispr | 0.45s |
| Hex | 0.5s |
| OpenSuperWhisper | **1.5s** |

OpenSuperWhisper は「ブラウザや Electron は post 後かなり経ってから `Cmd+V` を処理する」とコメントを残している。
固定 sleep は、短いと遅い消費者で貼り付けが空振りし、長いとユーザーのクリップボードを占有する。

## 判断

**Handy の promise pasteboard 方式**を採用する。固定 sleep を廃する。

1. `declareTypes:owner:` でデータではなく **promise** を置く
2. `pasteboard:provideDataForType:` コールバックを「消費者が実際に読んだ受領証」として使う
3. 受領証が途絶えてから `changeCount` ガード付きで元のクリップボードを復元する

合わせて最初から入れるもの:
- `V` の keycode は `TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` で解決（日本語配列・非 QWERTY 対策。Handy / macparakeet / anomalyco-hex / OpenSuperWhisper が実装）
- `org.nspasteboard.ConcealedType` / `TransientType` を併記してクリップボード履歴ツールに拾わせない
- Chromium / Electron 相手には `AXManualAccessibility` を明示 ON（TypeWhisper が実装）

## M2 実装で判明した順序の制約（2026-09-02）

- **修飾キーの解放待ちは promise を置く前に行う。** promise を置いた後に待つと、その間にクリップボード履歴ツールが promise を読み、
  受領証が `Cmd+V` より先に立って軸 A の測定が壊れる（実測で `paste_received < paste_posted` が発生）。
  順序は「修飾キー待ち → 退避 → promise → `Cmd+V` → 受領証 → 復元」
- 受領証タイムアウト時は本文をクリップボードに残し、履歴の `inserted_text` にも残す（`inserted: false`）

## T19 の実測による改訂（2026-09-04）— 受領証を復元の合図にするのをやめる

実機で **確定テキスト 843 文字のうち約 460 文字しか貼り付け先（Orca、Electron 系）に入らない欠落**が起きた。
`error` は null で受領証も来ており、vox 側は「成功」と判定していた。

オフスクリーンの pasteboard 検査（現在は `swift test --filter "PasteboardTests"`）で経路を 10 項目実測した結果（すべて PASS）:

| 観測 | 結果 |
|---|---|
| promise の 1 回目・2 回目・3 回目の読み | いずれも 843 文字。所有者は 1 回しか呼ばれない |
| promise 解決時の `changeCount` | 動かない |
| 復元後の読み | **nil（全部か無しか）。途中までにはならない** |
| 復元と読みの衝突 200 回 | partial 0 回、nil 62 回、最短 843 文字 |
| 33,720 文字 | 保たれる（pasteboard 側に長さ上限なし） |
| 別プロセスからの読み | 843 文字 |

**棄却した仮説**: 「消費者が複数回読む」（promise は 1 回で解決し、以後 pasteboard が実データを持つため 2 回目も全長）。
「460 文字の境界」（改行もなく、33,720 文字が無傷）。
**形が違うと分かった仮説**: 「復元が早すぎる」— 復元は読みを途中で切らない。作れるのは空振りだけ。

### 改訂 1: promise は維持する

「promise ではなく実データを置く」案は**却下**。実測で、promise でも実データでも 2 回目の読みは全長が返り、
遅い読み手に対する挙動が変わらないため。

### 改訂 2: 受領証を復元の合図に使うのをやめる（初版の判断の誤り）

受領証は「**最初に読んだ誰かの印**」で、貼り付け先アプリの印ではない。
本 ADR 自身が M2 の追記で「クリップボード履歴ツールが promise を読んで受領証が `Cmd+V` より先に立った」実測を記録していた。
実機ログの post → 受領証 21ms も、貼り付け先が読んだ証拠にならない。

**復元の猶予は `Cmd+V` の post から数える**（早い受領証で窓が縮まない）。猶予は貼り付け先で分ける:

- 既定 400ms
- **Chromium / Electron 系は 1,500ms**（bundle id の明示リスト + `Contents/Frameworks` の `… Helper.app` /
  `Electron Framework.framework` の有無で判定。Orca は該当、TextEdit は非該当を確認済み）

復元の直前にもう一度読み返し、置いた文字数と食い違う回は**復元せず確定テキストを残す**。
復元は別タスクに出し、HUD が閉じるのを待たせない。

### 改訂 3: 長さを必ず計測する

計測 JSONL に `pasted_chars`（置いた文字数）と `readback_chars`（受領証の直後に読み返した文字数）を出す。
**`readback_chars` が全長なら「消費者が読んだ時点で全量が載っていた」= 欠落は消費者側**と言い切れる。
次に同じことが起きたとき、推測ではなく JSONL で切り分けられる。

### 残る不確定要素

**欠落の原因は貼り付け先（Electron の入力欄）にある可能性が高いが、未証明。** 1,500ms でも切れる場合の次の手は
「Electron 系では復元しない」（確定テキストをクリップボードに残し HUD に告知）。復元よりも全量が入ることを優先する。

## 却下した案

| 案 | 却下理由 |
|---|---|
| 固定 sleep で復元 | 上記。値の正解が消費者依存で存在しない |
| `CGEvent` で Unicode を直接注入 | 日本語 IME と競合してドロップする既知の問題 |
| AX 直挿し（`AXUIElementSetAttributeValue`）を第一手 | TypeWhisper が採っているが、それも失敗時は paste に落ちる。対応アプリが限られる |

## 見直しの条件

- M1 の実測で promise の受領証が来ない消費者が見つかったとき → その消費者だけ固定 sleep にフォールバックする
- macOS 26 の WindowServer が合成イベントの送信元 PID を見て弾く挙動が本件に当たると分かったとき → 署名の前提化（設計書 §8）

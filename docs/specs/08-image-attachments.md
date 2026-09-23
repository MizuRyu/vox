# 08 画像の添付

HUD に貼った画像の扱い。判断の理由は [ADR-017](../adr/017-image-paste-as-file-path.md)。

最終確認日: 2026-09-23

## 要件

| # | 要件 |
|---|---|
| A1 | HUD が key の間、`⌘V` でクリップボードの画像データを本文に取り込める |
| A2 | 取り込みの結果として本文に入るのは**画像ファイルのパス**。画像そのものを貼り付け先へ渡さない |
| A3 | クリップボードにテキストがあるときは通常のテキストペーストのまま（本文を壊さない） |
| A4 | クリップボードにファイル URL があるときはコピーせず、そのファイルのパスを入れる（既存の T20 の挙動） |
| A5 | 複数の画像は貼った順に本文へ入る。削除は本文のパスを消すこと（`⌘Z` も効く） |
| A6 | 本文にパスがあるなら、そのファイルは存在する（書き込み完了後に挿入する） |
| A7 | 確定（トグル OFF）は、未完の書き込みを待ってから貼り付けへ進む。画像の処理中に Enter を押さない |
| A8 | 画像は履歴・計測・診断ログに残らない |

## 振り分け

`⌘V` の分岐は VoxCore の `AttachmentPaste` が決める（純粋関数。利用可能な型だけを見る）。
HUD の `VoxPanel` は `⌘V` `⌘C` `⌘X` `⌘A` `⌘Z` `⌘⇧Z` を Edit メニューを通さず、自分の first responder へ直接送る（対応は VoxCore の `HudEditCommand`）。アプリが active でない間は main menu のキー等価が届かない疑いがあるため。Edit メニューはそのまま残す。

| 順 | 条件 | 結果 |
|---|---|---|
| 1 | `.string` / `.rtf` / `.rtfd` / `.html` がある | 通常のテキストペースト |
| 2 | `.fileURL` がある | 既存ファイルのパスを挿入（コピーしない） |
| 3 | 対応形式の画像データがある | ファイルに書いてパスを挿入 |
| 4 | 画像は載っているが対応形式が無い | 何も入れず、対応していないことを伝える |
| 5 | 上記以外 | 通常のテキストペースト |

対応形式と拡張子（選ぶ優先順）: `public.png` → `png`、`public.jpeg` → `jpg`、`public.heic` → `heic`、`com.compuserve.gif` → `gif`、`public.tiff` → `tiff`。バイト列は再エンコードせずそのまま書きます。1 枚の上限は 32MiB で、超える画像は保存しません。PDF・ベクタ・動画は対象外です。

型名は VoxCore が文字列で持ちます（VoxCore は AppKit を持てない）。AppKit の値との一致は `VoxAppTests` が突き合わせます。

## UI と文言

- 成功時の表示は**本文に入ったパスだけ**。サムネイル列・専用の行は作りません
- パスの表記は既存のファイルペーストと同じ（検索対象のリポジトリ配下なら相対、外ならホーム基準で `~`。`FilePathFormat`）
- 挿入位置と前後の空白は `PaletteInsertion`（隣が空白・改行・タブなら重ねない）
- 失敗は HUD のキーヒントの行に 2.5 秒だけ出します。中段の `notice` は本文の表示と入れ替わるため、録音中の失敗には使いません

| 状況 | 文言 |
|---|---|
| 書き込みに失敗した（容量・権限・検証不合格）、または上限を超えた | `画像を保存できませんでした` |
| 画像は載っているが対応していない形式だった | `この形式の画像には対応していません` |

## データ

| 項目 | 値 |
|---|---|
| 保存先 | `~/Library/Application Support/vox/attachments/<yyyyMMdd>/<HHmmss>-<nn>.<拡張子>` |
| 権限 | ディレクトリ 0700、ファイル 0600。`O_CREAT|O_EXCL|O_NOFOLLOW` で作り、regular file・所有者・リンク数を検証する（`PrivateFileIO.write`） |
| 名前に含めるもの | 日時と連番だけ。発話内容・貼り付け先アプリ名・画像の内容は含めない |
| 回収 | 起動時に 1 回、作成から 7 日を過ぎたものと、残りが合計 500MiB を超える分を古い順に消す（判定は `AttachmentRetention`）。空になった日付フォルダも畳む |
| 履歴 | 画像は残さない。`inserted_text` に載るのは本文（パス文字列を含む）まで |
| 計測 | 項目を足さない（軸 A の母数に添付は影響しない） |
| 診断ログ | `attachment_saved kind=<形式> bytes=<数> path=<マスク済み>`、`attachment_rejected`、`attachment_save_failed`、`attachment_purged count=<数>`。パスは `--log-text` のときだけ出す。画像バイトは出さない |

## 自動 Enter との関係

`AutoEnterGate` に条件を足しません。書き込みは main actor の外で走り、**完了してからパスを挿入する**ため「本文にパスがある ⇒ ファイルがある」が不変になります。

確定は本文を読む前に、**HUD の key を返してから**走っている書き込みを待ちます（`closeInputForInsertion`）。順序が逆だと、待っている間に新しいペーストが始まります。key を返した後は `⌘V` が HUD に届きません。したがって貼り付けと Enter の時点に「終わっていない画像処理」は存在しません。

HUD を出し直すときは走っている書き込みを**すべて**捨てます（前の回のパスを次の本文に入れない）。差し込みは長さ 0 の位置に入れ、書き込みの間に選んだ文字は置き換えません。

## 制約

- 貼り付け先には画像そのものを渡しません。画像を表示して読ませたい相手（チャット、メール）には向きません（[ADR-017](../adr/017-image-paste-as-file-path.md) の見直しの条件）
- 画像のドラッグ＆ドロップ、スクリーンショットの撮影、画面領域の選択は範囲外です
- 回収した後にパスを開いても画像はありません（期限は 7 日）
- HUD が key でない間（`--no-edit-mode`）は `⌘V` が HUD に届かないので取り込めません
- 録音中に入力デバイスが変わって録音を終える経路では、貼る本文を決めた後に書き込みを待ちます。その待ち時間に完了した画像のパスは本文に入りません（ファイルは残るので、パスは保存先から辿れます）
- 保存先のリンク検査は日付フォルダとファイルまでです（`attachments` 自身をリンクに差し替えられた場合は追従します）。これは履歴・計測と同じ扱いで、変えるなら私的ファイル全体で一度に変えます
- 実機での `⌘V`、貼り付け先での読み取り、回収後の見え方は [ATT の TC](../MANUAL-VERIFICATION.md#att--画像の添付) で利用者が確認します

## 置き場

| 場所 | 型 |
|---|---|
| `Sources/VoxCore/Attachments/` | `AttachmentPaste`, `AttachmentImageKind`, `AttachmentFileName`, `AttachmentRetention`, `AttachmentFile` |
| `Sources/VoxCore/Process/` | `PrivateFileIO.write(_:creating:)` |
| `Sources/VoxApp/Support/` | `AttachmentStore`（保存と回収） |
| `Sources/VoxApp/Hud/` | `TranscriptImagePaste`、`TranscriptTextView.paste` の分岐、`HudModel` の待ち合わせと通知 |
| `Tests/VoxCoreTests/Attachments/` | 振り分け・名前・回収の検査 |
| `Tests/VoxAppTests/Hud/AttachmentPasteTests.swift` | 型名の突き合わせ、保存、差し込み、回収、待ち合わせ |

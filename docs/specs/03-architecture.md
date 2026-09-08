# 03 アーキテクチャ

プロセス構成、キー体系、テキスト契約、テキスト挿入、実装上の落とし穴。

最終確認日: 2026-09-07

**native Swift/SwiftUI 単一プロセス**。Python サイドカーも WebView も置きません。

現在の経路は `SpeechLane` → `VoxController`（フィラー除去）→ HUD → `Injector`。
録音セッションと認識実行は 1 回分の値として生成・破棄します（`RecordingSession` と `RecognitionRun`）。
長寿命の `VoxController` / `SpeechLane` は現在の 1 つだけを持ち、開始で作って終了で捨てます。
以下の図は確定レーンを含む将来構成であり、RingBuffer・VAD・ConfirmLane・辞書処理は現在の本体には未実装です。

```
┌─ AudioTap ────────── AVAudioEngine, 16kHz mono
│      ↓
├─ RingBuffer ──────── 直近 30 秒を保持（確定レーンの再投入元 + 押下前プリロール）
│      ↓         ↓
│  StreamLane   VAD ──── 発話区切り検出
│  (速報)         ↓
│      ↓      ConfirmLane (確定)
│      └────→ TextStore ←────┘
│                 ↓  committed / tentative + revision
│           DictionaryPass ── 語彙バイアス + 読み一致置換
│                 ↓
│           JapanesePostPass ── CJK 前後の空白・約物整形
│                 ↓
├─ HudPanel ────────── NSPanel(.nonactivatingPanel), floating level
│                 ↑
├─ HotkeyMonitor ───── 自前 CGEventTap
├─ FileIndex ───────── git status + fuzzy 検索
└─ Injector ───────── promise pasteboard + 合成 Cmd+V
```

## なぜ native Swift なのか

OSS 実装は **Tauri + Rust** と **native Swift** の二極に分かれています。Tauri を却下した理由は
「Web 技術が嫌だから」ではなく、**Tauri を選んでも AppKit から逃れられないことが実証されているから**です。
判断の記録は [ADR-001](../adr/001-macos-only-native-swift.md)。

`cjpais/Handy` (★30,737、Tauri v2) が実際に抱えているものを見ると:

- `tauri-nspanel` を git ブランチ直参照 (crates.io 未公開)
- `objc2` / `objc2-app-kit` / `objc2-foundation` で AppKit を FFI
- 自前 CGEventTap 実装 (Carbon と 2 バックエンドを Secure Event Input で切替)
- **Apple Intelligence を使うために `build.rs` から `swiftc` で Swift をコンパイルして C ABI で呼ぶブリッジ**
- そして macOS の推論バックエンドは `transcribe-cpp` の `metal` feature のみ = **ANE を使っていない**

つまり **AppKit を FFI 越しに Tauri の window ライフサイクルと整合させる作業**が発生し、
ANE に行きたければ結局 Swift を書いてビルドに `swiftc` を組み込むことになります。

さらに `tauri-nspanel` の open issue **#104「window level が高いと入力メソッド (IME) がブロックされる」**は、
日本語入力 HUD では設計が破綻しうる項目です。

**そして「軽くしたい」の主戦場はシェルではありません。**

```
モデル        478MB 〜 1.6GB   ← 支配項
Tauri シェル  約 46MB (+ WebKit 別プロセス)
Swift シェル  WebKit プロセス 0
```

シェル選定で節約できるのは数十 MB、モデル管理設計で節約できるのは 1GB です。
HUD 本体 (波形 + 状態 + テキスト) は Web 技術の利点がほぼ効かず、欠点だけが効く領域です。

実測 dmg サイズの参考値: Whispering 14MB / Hex 14MB / Handy 18MB / Vibe 36MB / VoiceInk 50MB に対し
**OpenWhispr (Electron) 316MB**。

推奨を覆す条件は 1 つだけ。**Windows / Linux も出すなら Tauri** です (Handy がまさにそれで、ANE を捨てる代償を払っている)。

## キー体系

録音はトグルのみ、挿入は終了時に一括（[ADR-004](../adr/004-toggle-recording-batch-insert.md)）。この 2 つから `Enter` で録音を終える必要がなくなり、
トグルキーが「開始」と「確定して挿入」を兼ねます。

| キー | 動作 | 備考 |
|---|---|---|
| `⌘⇧Space`（既定。`--toggle-key` と設定画面で変更可） | 開始 / **確定して挿入** | グローバル。M1 の実測で環境によって別のショートカットに先取りされたため、変更可能にした |
| `esc` | 破棄して閉じる | 挿入しない |
| `⌃P`（既定。`--palette-key` と設定画面で変更可）または HUD に `@` を入力 | コマンドパレット | 表示中も録音を継続 |
| `⌃Z`（将来案・未実装） | 直前セグメントを訂正 | 専用訂正モードの案 |
| `⌘D`（将来案・未実装） | 選択語を辞書に追加 | 専用訂正モードの案 |

パレット内では `↑` `↓` で選択、`Enter` でパスを挿入して閉じ、`esc` で挿入せず閉じる。録音は継続する。
`Enter` はパレットの中でしか使いません。

HUD の歯車と `--settings` から設定画面を開けます。録音・ファイル検索キーを保存でき、優先順位は
**起動引数 → 保存設定 → 既定値**。録音中の変更は終了後に反映します。キーの照合値を既存の event tap 上で更新するため、保存のたびの再登録は行いません。

設定画面が key window の間はホットキーの処理を止め、キー登録操作を録音・確定として扱いません。確定・貼り付け中の設定表示要求は待機し、idle に戻ったら開きます。閉じた際は表示中のパレット、または起動準備中・録音中の HUD に入力フォーカスを戻します。`--no-edit-mode` では HUD を key にしません。非アクティブパネルでの実際のフォーカス配送は利用者の実機確認を要します。

## 実装上の落とし穴（M0 で踏んだもの。本実装で再発する）

- **`AVAudioEngine` の tap クロージャを `@MainActor` の関数内に直書きすると main actor 隔離を継承し、
  オーディオスレッドで `dispatch_assert_queue` により SIGTRAP する**（Swift 6 言語モード）。
  `nonisolated static func makeTapBlock(...) -> AVAudioNodeTapBlock` の中で作って渡す形にすること
  （`Sources/VoxM0LiveProbe/main.swift` が実例）
- Apple `SpeechTranscriber` は `reportingOptions` に `.fastResults` がないと、ファイル給餌では finalize まで
  結果を出さない（[ADR-007](../adr/007-latency-measurement-method.md)）
- `AVAudioFile` は analyzer の `commonFormat` / `isInterleaved` で開くこと。既定の processingFormat で開くと
  結果が空になる。`AVAudioFile.length` は実データより多く報告されることがある（[ADR-007](../adr/007-latency-measurement-method.md)「測定の前提条件」）
- `finalize` を給餌と同じタスクから呼ぶと自己デッドロックする（[ADR-007](../adr/007-latency-measurement-method.md)）
- **多チャンネルの入力デバイスでは `AVAudioConverter` が先頭チャンネルしか使わない（仮説。未証明）。** 「外部マイク」が 48kHz/3ch のとき
  認識が 1 文字しか出ず、1ch のときは正常だった。先頭チャンネルが無音なら analyzer に無音が渡り、波形メーター（全チャンネル平均）だけが
  反応する説明になる。変換前に全チャンネル平均でモノラル化する（`BufferConverter.downmixToMono`）。
  **注意**: 当初「peak=0.0000 で無音を確認」と記録したが、これは診断コードが Int16 形式を読めず 0 を出していた誤診。証拠としては無効
- **analyzer の音声形式は Int16 のことがある**（`bestAvailableAudioFormat` が `common_format=3` を返した）。`floatChannelData` 前提のコードは nil を掴む
- **main queue を溢れさせると CGEventTap がタイムアウトで停止し、ホットキーが効かなくなる。** 波形更新（毎秒 15 回）の `updateNSView` で
  `DispatchQueue.main.async` を積んだら発生した。UI 更新は同期・回数制限で行う
- `.nonactivatingPanel` の `makeKey()` は約 1.2 秒後に key を失う挙動が観測されている。
  HUD を常時 key にする設計（R14）では `show()` で取り直しているが、維持されるかは実機確認が要る

## テキスト契約 — Handy 方式を採用する

現在は認識レーンの `committed` / `tentative` を HUD の `TranscriptBuffer` に反映します。
HUD 本文は **`head + tentative + tail`** の 3 区画。
`head` は未確定音声より前に確定した本文、`tail` はその音声の表示後に打った文字。
音声確定時は `head` に追記して `tentative` を空にする。新しい未確定音声が始まるときに `tail` を `head` に合流させ、時間順を保つ。
編集位置は全文の UTF-16 オフセットで管理し、`tentative` 内部は直接編集しない。

以下の `StreamTextEvent` は初期のイベント契約案。現在の HUD の型・編集モデルを表すものではありません。

`StreamTextEvent { committed, tentative, revision }` の 2 段テキスト契約にします。

- `committed` は**追記専用**。一度出したら動かさない → UI 側でフリッカが原理的に起きない
- `tentative` はモデルが書き換えうる suffix
- `revision` 番号で順序を保証する

VoiceInk は「単語を正規化して 3 回一致したら確定」する `WordAgreementEngine` を実装していますが、
**日本語は分かち書きがないためこの方式は移植できません**。文字 / subword 単位で確定判定するしかなく、
これも真のストリーミングモデルを選ぶ理由になります。

## テキスト挿入 — 全実装共通の地雷を最初から避ける

クリップボード + 合成 Cmd+V に業界が収束しています。ただし**クリップボード復元のタイミングが共通の地雷**で、
各実装の待ち時間が VoiceInk 0.25s / Whispering 0.1s / OpenWhispr 0.45s / Hex 0.5s / OpenSuperWhisper **1.5s**
とばらけています。OpenSuperWhisper は「ブラウザや Electron は post 後かなり経ってから Cmd+V を処理する」と
コメントを残しています。

最良の解は **Handy の promise pasteboard 方式**です（[ADR-009](../adr/009-text-insertion-promise-pasteboard.md)）。固定 sleep を廃せます。

1. `declareTypes:owner:` でデータではなく **promise** を置く
2. `pasteboard:provideDataForType:` コールバックを「消費者が実際に読んだ受領証」として使う
3. 受領証が途絶えてから `changeCount` ガード付きで元クリップボードを復元

合わせて最初から入れるもの:

- **V の keycode を `TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` で解決** (日本語配列・非 QWERTY 対策)
- `org.nspasteboard.ConcealedType` / `TransientType` を併記してクリップボード履歴ツールに拾わせない
- **Chromium / Electron 相手には `AXManualAccessibility` を明示 ON** (TypeWhisper が実装)

## RingBuffer

状態: 未実装（将来）。

直近 30 秒の PCM を保持します。用途は 2 つ。確定レーンの再投入元と、**ホットキー押下前のプリロール**
(押した瞬間の言い出しを取りこぼさない)。

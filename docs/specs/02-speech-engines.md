# 02 音声エンジン

採用している認識エンジン、その実測値と制約、比較して却下した候補。

最終確認日: 2026-09-07

## いま動いているもの

**Apple `SpeechTranscriber`（macOS 26 / ja_JP）1 本だけ。** 他のモデルは 1 つも積んでいない。

| 項目 | 値 |
|---|---|
| API | `Speech` framework の `SpeechAnalyzer` + `SpeechTranscriber`（macOS 26 で追加） |
| ロケール | `ja-JP`（`supportedLocales` に実在することを実測で確認済み） |
| モデルの置き場所 | **アプリのメモリ空間外**（OS が管理）。Vox のバイナリにも RAM にも乗らない |
| 初回のダウンロード | 必要。約 24 秒。一度入れば以後は不要（`AssetInventory` の状態が `installed` になる） |
| 実行先 | Apple Neural Engine（OS 側の実装。Vox からは指定しない） |
| ネットワーク | 初回のモデル取得のときだけ。以後は完全ローカル |

### 必須の設定 — `.fastResults`

```swift
SpeechTranscriber(
  locale: ja-JP,
  transcriptionOptions: [],
  reportingOptions: [.volatileResults, .fastResults],   // ← .fastResults が必須
  attributeOptions: []
)
```

**`.fastResults` がないと、`finalize` を呼ぶか入力が終わるまで結果を一切出さない。**
これは M0 の実験で確定させた事実で、ドキュメントには書かれていない。詳細は
[ADR-007](../adr/007-latency-measurement-method.md)（測定記録は非公開）。

### 実測した性能

| 指標 | 値 | 測り方 |
|---|---|---|
| 初出遅延（喋り始めてから最初の文字まで） | **0.78〜1.53 秒** | 約 1 秒周期の tick 待ち。周期を変える API は見つかっていない |
| 確定処理（finalize）| 約 75〜210ms | 発話が長いほど伸びる |
| 発話終了 → 挿入完了 | **166 / 244 / 316 / 570 / 692ms**（実測 5 回） | 看板指標。目標は 300ms、許容 500ms |
| 日本語 CER | **未測定** | 合成音声では 0〜0.16。実発話の正式値はコーパス録音待ち |

初出遅延が約 1 秒あるのは Apple の性質で、変えられない。だから「速さ」の看板を
**発話終了 → 挿入完了**に移した（[ADR-010](../adr/010-speed-metric-axis-a-apple.md)）。最初の 1 秒は「聞いています」表示で埋めている。

### Apple の API でできないこと

**語彙バイアス（辞書をモデルに教える）の公開 API が存在しない。**

`Speech` framework のドキュメントを調べた範囲では、認識前に単語リストを渡して優先させる仕組みが見つからなかった。
そのため「末尾」が「松尾」になる、「形態素解析」が「携帯素解析」になる、といった誤りは
**認識後のテキストを置換する**しか手がない（[05 テキスト後処理](05-text-postprocessing.md)の L2）。

これが後述の「モデルのアダプター化」を検討する理由になっている。

---

## 速報レーンの選定 — Apple に決定

以下は比較時の記録。結論は Apple `SpeechTranscriber` + `.fastResults` で、根拠は
[ADR-010](../adr/010-speed-metric-axis-a-apple.md)（測定記録は非公開）。

| 案 | 実体 | 日本語精度 | 初出遅延 | 待機コスト |
|---|---|---|---|---|
| **A（採用）** | Apple `SpeechTranscriber` (macOS 26, ja_JP) | 疑似音声で CER 0.158 / 0 / 0（傾向のみ。正式値は自作コーパス待ち） | `.fastResults` モード: **782〜1446ms**（ファイル給餌）/ **1530ms**（ライブ、1 サンプル）。約 1s 周期の tick 待ち。自然モードは発話中に発火しない | **モデルがアプリのメモリ空間外**。初回のみ約 24s の DL が必要 |
| **B（フォールバック）** | FluidAudio `Nemotron-...-Multilingual-CoreML` | FLEURS ja CER 13.79% @2.24s / 14.61% @0.56s | **560ms が下限** | 672MB / peak RSS 141〜142MB |

**A を採った理由**は 3 つあります。

1. **待機コストが構造的に勝つ。** WWDC25 で「モデルはアプリのメモリ空間外で動き、アプリの download / storage / runtime memory を増やさない」と明言されています。常駐 0.6B モデルが 2 個から 1 個に減ります
2. **volatile → final の上書きが OS 側に実装済み。** `.volatileResults` を有効にすると「realtime guesses」を出し、音声が増えた時点で finalized が earlier results を置き換えます。二段化の片方が既製品で手に入る
3. **B には 560ms の床がある。** FluidAudio の `NemotronChunkSize` は 2240 / 1120 / 560ms の 3 値のみ。上流 NVIDIA は 80 / 160 / 320ms も持っていますが、CoreML 変換版では使えません

**A の残る不安は、日本語 CER の公表値が存在しないこと。** 英語 LibriSpeech では WER 2.12% で Whisper Small (3.74%) を上回りますが、これを日本語の根拠には使えません。実発話コーパスでの CER 実測は残件です。

実在証明について（2026-09-02 訂正）。初版では `Kuberwastaken/megaphone` を「真のストリーミング」の実例として挙げたが、
ソースを確認した結果 **megaphone は `reportingOptions: []` で未確定結果を購読しておらず、停止時に全文を返す実装**だった
（参照実装の差分収集 E4、非公開の測定記録）。発話中に未確定テキストを表示している参照実装は **Apple 公式サンプル (WWDC25-277) のみ**。

## 確定レーン — 未実装。採用モデルは決定済み

`FluidInference/parakeet-0.6b-ja-coreml` (`nvidia/parakeet-tdt_ctc-0.6b-ja` の CoreML 変換)。
決定の根拠は [ADR-003](../adr/003-confirm-lane-parakeet-ja.md)。本体への組み込みは未着手。

| 指標 | 値 |
|---|---|
| JSUT basic5000 CER | 平均 6.88% / **中央値 4.08%** |
| FLEURS ja CER | 10.29% |
| 平均レイテンシ | 208.8ms |
| RTFx | 28.9× (M2) |
| 実行先 | ANE |
| ライセンス | CC-BY-4.0 |

独立した外部ベンチ (HEROZ, A100) でも、**ローカル実行・低 RTF・JSUT 最良の交点**がこのモデルでした
(JSUT CER 6.60 / RTF 0.01〜0.03。whisper-large-v3 は 7.01 / RTF 0.15〜0.23)。

中央値 4.08% が平均 6.88% を大きく下回るのは、「ほとんどの発話はかなり正確で、一部の難発話が平均を押し上げている」
という分布を意味します。辞書と訂正（[05](05-text-postprocessing.md)）が効くのはこの裾の部分で、機能配置として噛み合っています。

## フォールバック候補 — Nemotron（実装していない）

**Nemotron 3.5 Streaming Multilingual 0.6B（FluidAudio 経由の CoreML）。**

| 項目 | 値 |
|---|---|
| 日本語 CER | FLEURS 13.79%（Apple より劣る見込み） |
| 初出遅延 | 0.74〜1.5 秒（Apple とほぼ同じ。チャンクの下限が 560ms） |
| 常駐メモリ | 約 142MB（Apple は 0） |
| **語彙バイアス** | **公開 API がある**（`VocabularyBoostingSession` / `NemotronVocabularyBias.setCustomVocabulary`） |

**このモデルの唯一の優位は最後の 1 行。** 辞書をデコード段で効かせられる可能性がある。
ただし内部が英語のストップワード前提なので、**日本語で機能するかは未検証**。

M0 の測定ハーネス（`vox-m0`）には Apple と Nemotron の両方が実装済みなので、比較はいつでもできる。

## モデルのアダプター化

**本当の価値は「辞書がデコード段で効くモデルを試せること」**にある。認識後の置換（[05](05-text-postprocessing.md) の L2）より原理的に強い。
Apple は語彙バイアスの API を持たないので、Apple のままではこの道が閉じている。

現状は `SpeechLane` が Apple に直結していて、差し替え可能な境界になっていない。
やるなら `SpeechEngine` プロトコル（`start` / `feed` / `finalize` / `results`）を切り出し、Apple と Nemotron の 2 実装を置く。
M0 のハーネスに両方あるので、そこから移植できる。

**着手の判断は、コーパス 100 文の CER を測ってから。** Apple の実発話精度が十分なら、
142MB の常駐を足してまで辞書のために切り替える価値があるかは別の話になる。

## 却下したもの

| 却下 | 理由 |
|---|---|
| **Parakeet TDT v3** | **日本語 CER 159%**（macparakeet の M4 Pro 実測）。公式カードは欧州 25 言語のみで日本語非対応。FluidAudio と vocamac の README が「ja 対応」と書いているのは**誤り**。混同事故が実際に起きているモデル |
| **Whisper 系すべて（速報）** | 30 秒固定窓・チャンクごとのエンコーダ再計算・hallucination。**短いチャンクを頻繁に投げるのが最も hallucinate しやすい入力形式**という構造的ジレンマ。`whisper_streaming` の報告遅延は英語で 3.3s |
| **Whisper Tiny** | 上記に加え精度。日本語 CER の実測は見つからず |
| **kotoba-whisper v2.x** | 日本語精度は良い (JSUT 7.36) が Whisper 系でストリーミング不可。バッチ書き起こしなら第一候補 |
| **Cohere Transcribe** | FLEURS ja CER 5.56% は全候補中最良だが **peak RSS 約 11.6GB / 約 11× realtime**。常駐要件と正面衝突 |
| **Qwen3-ASR 0.6B（速報）** | CoreML 版あり・日本語も良好だが **RTFx 2.8〜4.5×**（Nemotron の 84× に対し 20〜30 倍遅い）。確定レーンの代替候補としてのみ |
| **Voxtral-Mini-4B-Realtime** | 真のストリーミングで ja WER 9.59%@480ms は魅力的だが **4B・GPU 前提**。CoreML 変換なし |
| **SenseVoice Small** | 241MB / RAM 0.5GB / ja 対応で最軽量だが**ストリーミング非対応** |
| **sherpa-onnx（速報）** | 公式ドキュメントに**日本語 online モデルが 0 件**。非公式の多言語 streaming zipformer 1 本のみで動作未検証。ANE も使えない |
| **ReazonSpeech** | k2 / nemo / espnet **全版が非ストリーミング**。2024-08 に streaming 版を予告したが未リリース。確定レーン候補としては JSUT 6.45% で有力 |
| **parakeet-mlx / mlx-audio** | MLX は **GPU で ANE を使わない**。加えて Python 常駐が R8 に反する |
| **NVIDIA NeMo を Mac で直接** | `triton` に Apple Silicon wheel がなく導入で詰まる。MPS は未実装 op のフォールバック前提。**モデル変換用途に限る** |

## 関連する記録の場所

| 知りたいこと | 見る場所 |
|---|---|
| なぜ Apple を選んだか、何を却下したか | [ADR-010](../adr/010-speed-metric-axis-a-apple.md)、[ADR-003](../adr/003-confirm-lane-parakeet-ja.md) |
| `.fastResults` を突き止めた経緯（誤った仮説 3 つと反証） | [ADR-007](../adr/007-latency-measurement-method.md)（測定記録は非公開） |
| 遅延と CER の生データ | 非公開（端末情報を含むため公開リポジトリに含めない） |
| 二段構成（速報 + 確定）の設計 | [01 要件](01-requirements.md) |
| 出典の一覧 | [references](references.md) |

# ADR-003: 確定レーンに `parakeet-0.6b-ja-coreml` を使う

- 状態: **承認**
- 日付: 2026-09-01
- 関連: 設計書 §3

## 判断

確定レーンは `FluidInference/parakeet-0.6b-ja-coreml`（`nvidia/parakeet-tdt_ctc-0.6b-ja` の CoreML 変換）。
FluidAudio 経由で ANE 実行。

## 理由

| 指標 | 値 | 出典 |
|---|---|---|
| JSUT basic5000 CER | 平均 6.88% / **中央値 4.08%** | FluidAudio Benchmarks |
| FLEURS ja CER | 10.29% | 同 |
| 平均レイテンシ / RTFx | 208.8ms / 28.9× (M2) | 同 |
| 独立ベンチ (HEROZ, A100) | JSUT 6.60 / RTF 0.01〜0.03 | HEROZ Tech Blog 2026-08-18 |

独立ベンチでも**ローカル・低 RTF・JSUT 最良の交点**がこのモデル。
中央値 4.08% が平均を大きく下回る分布は「ほとんどの発話は正確で一部の難発話が平均を押し上げる」ことを意味し、辞書と訂正機能が効く裾と噛み合う。

## 却下した案

| 案 | 却下理由 |
|---|---|
| Parakeet TDT v3 | **日本語 CER 159%**（macparakeet の M4 Pro 実測）。公式カードは欧州 25 言語のみ。FluidAudio と vocamac の README が「ja 対応」と書いているのは誤り。混同事故が実際に起きているモデル |
| Cohere Transcribe | FLEURS ja CER 5.56% で全候補中最良だが **peak RSS 約 11.6GB / 約 11× realtime**。常駐要件と正面衝突 |
| kotoba-whisper v2 | JSUT 7.36 で良いが Whisper 系。確定レーンには使えるが、parakeet-ja に劣る |
| ReazonSpeech k2 | JSUT 6.45 で有力。parakeet-ja と同等だが CoreML 変換が無く sherpa-onnx (CPU) 経路になる |
| Qwen3-ASR 0.6B | CoreML 版あり・日本語良好だが RTFx 2.8〜4.5× |

## 見直しの条件

- 自作コーパスでの CER が想定（7% 前後）を大きく外れたとき
- 日本語 CER で明確に上回る CoreML 対応モデルが出たとき（ReazonSpeech の CoreML 変換など）

# ADR-036: Haasの既定モデルにHaas-ja-v1.0-dialogue Q4_Kを採用する

- 状態: **承認**
- 日付: 2026-11-27
- 関連: [ADR-032](032-switchable-haas-and-apple.md)、[ADR-034](034-haas-hot-standby.md)

## 判断

`dena-ai/Haas-ja-v1.0-dialogue` のQ4_Kを既定のHaasモデルにする。旧モデル `third-intelligence/Haas-ja-v1.0` を対話向けに追加学習したApache-2.0のモデルで、FastConformer + KDAの構成とテンソル数683は共通する。量子化元の対話モデルはリビジョン `8722f3f855b2d6a1327d46c2d8d3dfaa842b5890` に固定する。[固定リビジョン](https://huggingface.co/dena-ai/Haas-ja-v1.0-dialogue/tree/8722f3f855b2d6a1327d46c2d8d3dfaa842b5890)

GGUFはspeech.cpp v0.10.0の `speech quantize --type q4_k` で量子化した。GitHub Release `model-haas-ja-v1.0-dialogue-q4-r1` に `Haas-616M-ja-v1.0-dialogue-Q4_K.gguf` とApache-2.0のライセンス全文（`LICENSE`）を同梱して配布し、本体はSHA256 `514cb8ad2ee23833153ab8329bad3af50edc645c05e36cd516afca22bd61e91d` で検証する。保存先は `models/haas-v1-q4` とし、検証済みの実行ファイル、ライブラリ、Silero VADモデルを再利用する。[配布アセット](https://github.com/MizuRyu/vox/releases/tag/model-haas-ja-v1.0-dialogue-q4-r1)

## 量子化の比較

M4・32GBで、speech.cpp v0.10.0、4スレッド、Silero VADを使用した。処理時間、実時間比のRTF、ピークRSSは実録音40本、計681.3秒で測定した。文字誤り率のCERは正解文がある合成音声10本で測定した。

| 指標 | Q4_K | Q8_0 |
|---|---:|---:|
| 重みのサイズ | 336MiB、351,901,216バイト | 626MiB |
| ピークRSS | 488.6MiB | 793.2MiB |
| 処理時間 | 4.04秒 | 4.53秒 |
| RTF | 0.0059 | 0.0067 |
| 合成音声のCER | 31.40% | 31.71% |

実録音の出力は40本中11本が完全一致し、句読点の正規化後は16本が一致した。文字差分率は正規化後2.80%、正規化前3.91%だった。合成音声のCERの差は0.31ポイントで、Q4_KはピークRSSを約305MiB削減するため採用する。実録音の文字差分率は両モデルの出力間の差を示す。

## 旧モデルとの比較

同じ実録音40本と、音量が−60dBFS未満の実録音10本で比較した。モデルの読み込み後の処理時間は合成音声10本で測定した。

| 指標 | 旧Haas Q4_K | 対話モデルQ4_K |
|---|---:|---:|
| 低音量の録音で認識結果が出た件数、VADなし | 1/10 | 0/10 |
| 同件数、Silero VADあり | 0/10 | 0/10 |
| 句点 `。` | 6 | 63 |
| 読点 `、` | 8 | 46 |
| 疑問符 `？` / `?` | 12 | 29 |
| 不要な半角スペース | 16 | 7 |
| ASCII・英語表記の用語（`[A-Za-z][A-Za-z0-9_.-]+` のクリップ内ユニーク語数合計。2文字以上英字語 `[A-Za-z]{2,}` の延べ出現数は14対5） | 13 | 6 |
| モデル読み込み後の処理時間 | 0.49秒 | 0.50秒 |
| ピークRSS | 502.3MiB | 490.4MiB |
| 合成音声10本のCER | 28.35% | 31.40% |

対話モデルは句読点を多く出力し、不要な半角スペースが減った。音声入力の整形に関わるこの変化を採用理由とする。英語の用語にはカタカナ表記が増え、合成音声のCERは上昇した。デコード時の `--keywords` と確定時の `dictionary.tsv` で個別の表記を補正できる。合成音声では読み付きの用語指定で表記が変化することを確認した。

## 却下した候補

| 候補 | 理由 |
|---|---|
| `parakeet-tdt_ctc-0.6b-ja-dialogue` | CC-BY-4.0。speech.cppで `--keywords` を使用できず、基礎認識精度もHaasより低い（`asr-ja-bench` v1.1で元モデル7.23%対Haas 6.12%、DeNAモデルカード） |
| `nemotron-3.5-asr-streaming-0.6b-ja-dialogue` | Apache-2.0以外のライセンスで、数値を漢数字で出力する。speech.cpp v0.10.0では未対応（DeNAモデルカード） |
| Qwen3-ASR 1.7B | Third Intelligence公開の `asr-ja-bench` v1.1でCER 7.59%（Haas 6.12%）と高く、処理時間が長く、重みも大きい |
| Nemotron 3.5 Transcribe | IQ4_NLの重みが19GBで常駐用途の容量が大きく、`asr-ja-bench` v1.1でもHaasより精度・速度で劣る |

## 見直しの条件

- 実利用で句読点の誤挿入や英語・技術用語の誤認識が増え、用語ヒントと辞書による補正後も修正が頻発する場合は、正解付きの同一コーパスで旧モデルと再比較する。
- 少ないメモリで同等以上の認識精度と処理時間を満たす候補が出た場合、またはQ8_0が実利用の修正件数を明確に減らす場合は、ピークRSSも含めて比較する。
- speech.cppを更新する場合は、固定したモデル、Silero VAD、ワーカープロトコル、用語ヒントの互換性を合成音声で再検証する。

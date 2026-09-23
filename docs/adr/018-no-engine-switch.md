# ADR-018 認識エンジンの切り替えを本体に入れない

- 状態: 承認
- 日付: 2026-09-23
- 関連: [02 音声エンジン](../specs/02-speech-engines.md)、[ADR-002](002-two-lane-transcription.md)、[ADR-003](003-confirm-lane-parakeet-ja.md)、[ADR-010](010-speed-metric-axis-a-apple.md)、[既知の問題と制約](../KNOWN-ISSUES.md)

## 文脈

設定から音声認識モデルを選べるようにする案（旧計画の T30）を、`docs/KNOWN-ISSUES.md` の「未実装（計画あり）」に置いたままにしていた。初期案は Apple と Nemotron を本体で選択可能にすることだった。

2026-09-23 に候補の現状を公開情報で確認した（GitHub の README・リリース・ドキュメントを `gh api` で取得）。

**日本語でストリーミング認識できるローカル候補は 1 本しか増えていない。** FluidAudio は v0.16.1（2026-09-21）まで進み、本体のベンチが固定している v0.15.0（2026-06-04）から 8 リリース分の差がある。それでも [Documentation/Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md) の「Streaming Transcription (True Real-Time)」に並ぶ 4 つのうち日本語に対応するのは Nemotron 3.5 Streaming Multilingual 0.6B だけで、Parakeet EOU・Nemotron 英語版・Parakeet Unified streaming はいずれも英語専用である。

**その 1 本の日本語精度は動いていない。** [Documentation/ASR/NemotronMultilingual.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/NemotronMultilingual.md) の 2026-06-28 再測定（FLEURS 全 test split、Apple M2、int8、ja n=650）で ja の CER は 560ms 14.27% / 1120ms 13.79% / 2240ms 13.78%。同じ節が「精度はチャンクを大きくするほど単調に良くなる」と明記しており、速報レーンが欲しい短いチャンクほど悪い。処理チャンクの下限は 560ms のままで、全ビルドが lookahead なし（`att_context_size=[56,0]`）である。

**WhisperKit には検討材料がない。** OSS 側（v1.1.0、2026-08-06）が積んでいるのは OpenAI Whisper の tiny / base / small / large-v3 だけで、日本語専用モデルはない。README 冒頭が、リアルタイム認識と custom vocabulary は有償の Pro SDK 側の機能だと明記している。Whisper 系を速報レーンから外した [ADR-010](010-speed-metric-axis-a-apple.md) の判断は変わらない。

**バッチ側の parakeet-0.6b-ja-coreml も状況は同じ**で、日本語専用・バッチ専用のまま JSUT basic5000 で平均 CER 6.88%（[ADR-003](003-confirm-lane-parakeet-ja.md) の記録と一致）。ReazonSpeech も v3.0.0（2026-01-15）でストリーミング版は出ていない。

そして**比較の基準そのものがない**。Apple `SpeechTranscriber` の日本語 CER は実発話コーパスで測っていない（[02 音声エンジン](../specs/02-speech-engines.md)「未測定」）。切り替え先が Apple より良いか悪いかを判定できない。

## 決定

1. **認識エンジンの切り替えを本体に入れない。** 認識は Apple `SpeechTranscriber`（ja-JP）1 本のままにする。設定項目・モデル一覧・モデル取得の UI を作らない。
2. `docs/KNOWN-ISSUES.md` の「本体のモデル切り替え」を「未実装（計画あり）」から外し、制約として書く。「計画あり」は着手の見込みを意味するが、着手の前提（自作コーパスでの CER 測定）が未了で、見込みを示せない。
3. **`SpeechEngine` / `Transcriber` のような protocol を先に切らない。** 2 つ目のエンジンが本体に実在するまで抽象を作らない方針を維持する。`SpeechLane` の音声取り込みと認識を型として分ける整理はエンジンが 1 本でも意味があるが、これはエンジン切り替えとは別の作業として扱う。
4. **`MetricsRecord` に engine / model の欄を足さない。** 値が常に Apple になる欄は、将来のための追加になる。2 つ目のエンジンと同時に足す。
5. **辞書はモデルへの語彙バイアス（L1）に依存しない設計を維持する。** Apple に語彙バイアスの公開 API がないため、認識後の読み一致置換（[05 テキスト後処理](../specs/05-text-postprocessing.md) の L2）を唯一の手段として進める。この結論は本 ADR で変わらない。
6. **二段構成（[ADR-002](002-two-lane-transcription.md)）は本 ADR の対象外**として維持する。区別は下記。

エンジン切り替えと二段構成は別物である。二段構成の確定レーンは、貼り付ける本文の精度を上げるために、発話区切りごとに 1 回だけバッチモデル（parakeet-ja、JSUT 中央値 4.08%）を通す設計で、[ADR-002](002-two-lane-transcription.md) / [ADR-003](003-confirm-lane-parakeet-ja.md) に根拠と数字がある。エンジン切り替えは速報レーンをより CER の悪いモデル（13.8%）に差し替えて、デコード段の語彙バイアスという別の手段を得る案だった。両方を積むと常駐 0.6B モデルが 2 つになり、Apple を採った [ADR-010](010-speed-metric-axis-a-apple.md) の第 1 の理由を打ち消す。未実装の 2 つのうち先に検討するのは確定レーンである。

## 却下した案

- **Apple と Nemotron を設定で選べるようにする（旧 T30 の初期案）**: 日本語 CER で Apple に勝てる見込みがなく、常駐 0.6B・560ms のチャンク下限・句読点が疎になる挙動を追加で背負う。得られるのはデコード段の語彙バイアス 1 点だけで、その日本語での効果は公開情報でも未測定。
- **判定できないまま切り替えを入れ、利用者に選ばせる**: どちらが良いかを示せない選択肢は、設定を増やすだけで判断を利用者に押し付ける。不具合の切り分けも難しくなる。
- **2 つ目のエンジンがないまま protocol だけ先に切る**: 実装が 1 つしかない抽象が残る。境界の妥当性も、比較するものがないまま決められない。
- **確定レーンを先に入れて、そこへ語彙バイアスを載せる**: 方向としては切り替えより筋が良い。ただし FluidAudio の CTC rescorer 系の語彙バイアスは英語学習の CTC エンコーダを別途ロードする経路で、日本語モデルに載るという記述が公開情報にない。デコード段バイアスの CJK 対応は Nemotron 側にしかない。計画として書ける段階ではないため、確定レーン自体の着手判断とは分けて未解決の問いとして残す。
- **本体に FluidAudio を追加してベンチと実装を共有する**: 本体の `Package.swift` は外部依存を持たない（[ADR-013](013-library-app-and-test-targets.md)）。FluidAudio は C shim 2 つと、事前ビルドの Rust xcframework（`NemoTextProcessing`）を持つ。swift-tools 6.2 の trait で xcframework は外せるが、外部依存を持ち込む判断自体が必要になる。切り替えを入れないので、この判断も発生しない。

## 検証と限界

公開情報の確認だけで、測定はしていない。本 ADR は「Apple の方が正確だから切り替えない」ではなく、**良し悪しを判定できないので切り替えない**という判断である。

- 出典は GitHub のみ（`gh api` で取得）。HuggingFace のモデルカードは確認していない。配布サイズとライセンス表記の現況は未確認である
- Apple の日本語 CER は今回も測っていない。実発話コーパスでの測定は「モデル比較条件の統一」の作業に残る
- Nemotron の日本語での語彙バイアスの効果と誤爆は、上流でも測られていない。上流の false-fire プロファイルは LibriSpeech（英語）のみである
- 本体の挙動を変えないため、実機確認項目は増えない

## 見直しの条件

- **自作コーパス 100 文で Apple の日本語 CER を測り、日本語に対応するストリーミングエンジンがそれを下回ったとき。** 確認は「モデル比較条件の統一」で整えた同条件の比較表（`just bench-report`）。これが主条件であり、上流に新しいモデルが出ただけでは本 ADR を蒸し返さない
- 認識後の読み一致置換（L2）を入れた後も、辞書で直せない誤りが残るとき。確認は履歴に残る打ち直しの回数。デコード段の語彙バイアスを手段として再検討する
- Apple が日本語で語彙バイアスの API を公開したとき。この場合は切り替えではなく、Apple のまま L1 が手に入る
- ANE で動き、日本語 CER で Apple を明確に上回るストリーミングモデルが出たとき（[ADR-010](010-speed-metric-axis-a-apple.md) の既存条件）。確認は FluidAudio の `Documentation/Models.md` の Streaming Transcription の表に日本語対応の項目が増えること。README の言語一覧を根拠にしない（Parakeet TDT v3 の混同事故がそれで起きた）

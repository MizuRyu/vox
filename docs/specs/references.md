# references 出典

仕様の根拠にした外部資料。

最終確認日: 2026-09-07

## モデル

- [nvidia/parakeet-tdt_ctc-0.6b-ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) — 確定レーン元モデル。JSUT CER 6.4%、ReazonSpeech v2.0 35k 時間
- [FluidInference/parakeet-0.6b-ja-coreml](https://huggingface.co/FluidInference/parakeet-ctc-0.6b-ja-coreml) — その CoreML 変換
- [nvidia/nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) — 速報レーンのフォールバック候補の上流 (canonical repo 名)
- [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — **日本語非対応**。混同注意
- [kotoba-tech/kotoba-whisper-v2.0](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0) — 却下したバッチ候補

## ランタイム / SDK

- [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) — Swift SDK 本体。語彙バイアス API の所在
- [FluidAudio Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md) / [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- [argmaxinc/argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) — WhisperKit の統合先
- [WWDC25-277 SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) — モデルがアプリのメモリ空間外で動く根拠

## 参考実装

- [cjpais/Handy](https://github.com/cjpais/Handy) — `committed`/`tentative` 契約、promise pasteboard、CGEventTap 2 バックエンド
- [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) — CJK issue 群、モデル別 RAM 表、`CursorPaster`
- [moona3k/macparakeet](https://github.com/moona3k/macparakeet) — **日本語 CER の実測 (M4 Pro / FLEURS)**、peak RSS
- [Kuberwastaken/megaphone](https://github.com/Kuberwastaken/megaphone) — Apple `SpeechAnalyzer` 一本足の実在証明
- [anomalyco/hex](https://github.com/anomalyco/hex) — モデル × 言語ゲート、レイテンシ実測
- [EpicenterHQ/epicenter ADR-0016](https://github.com/EpicenterHQ/epicenter/blob/main/docs/adr/0016-prewarm-the-cold-model-load-and-refuse-the-rest-of-the-latency-menu.md) — chunk-and-stitch を拒否した意思決定
- [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) — `asian-autocorrect`、復元 1.5s の実測コメント

## 理論

- [Partial Rewriting for Multi-Stage ASR (arXiv:2312.09463)](https://arxiv.org/abs/2312.09463) — 二段構成の flicker 効果
- [Cache-aware streaming Conformer (arXiv:2312.17279)](https://arxiv.org/abs/2312.17279)
- [NeMo ASR docs](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/models.html) — look-ahead の層積算
- [Careless Whisper (FAccT 2024)](https://facctconference.org/static/papers24/facct24-111.pdf) — hallucination 1.4%

## ベンチ

- [HEROZ 日本語 ASR 11 モデル比較 (2026-08-18)](https://techblog.heroz.jp/entry/2026/08/18/120000)
- [Lyonesse — Apple Speech API benchmark](https://lyonesse.app/blog/apple-speech-api-benchmark.html) — 英語のみ。日本語の根拠には使えない
- [Sansan Tech Blog — SpeechAnalyzer 比較](https://buildersbox.corp-sansan.com/entry/2026/02/13/130000) — 日本語での実務的な落とし穴

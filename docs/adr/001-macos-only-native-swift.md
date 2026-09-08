# ADR-001: macOS 専用とし、シェルは native Swift/SwiftUI にする

- 状態: **承認**（2026-09-02。M0 で速報エンジンが Apple `SpeechTranscriber` に決まり、Swift 専用 API が中心になったため。ADR-010）
- 日付: 2026-09-01
- 関連: 設計書 §0 決定 1・10、§4

## 文脈

vox は完全ローカルの日本語音声入力 HUD で、「速さ」を売りにする。
候補は native Swift / Tauri (Rust + WebView) / GPUI (Rust, Zed の UI) / Electron。
ユーザーは当初 GPUI に関心があった。

## 判断

**macOS 専用。シェルは native Swift/SwiftUI。** Windows / Linux は出さない。

## 理由

1. **速報レーンの第一候補 Apple `SpeechTranscriber` は Swift 専用 API。** Rust から使うと、最もレイテンシに敏感な経路だけが FFI 越しになる。「Swift を避ける」のではなく「Swift + 境界」が増えるだけ
2. **クロスプラットフォームを狙うと ANE を捨てることになる。** 実証: Handy (Tauri, ★30k) は `tauri-nspanel` の git 直参照、`objc2` で AppKit を FFI、`build.rs` から `swiftc` を呼ぶブリッジまで抱えたうえで、推論は Metal のみで ANE を使っていない。anomalyco/hex (GPUI) も `apple_speech.swift` を抱え、ANE を使っていない
3. **GPUI は pre-1.0 で破壊的変更が明言され、Windows 非対応**（macOS / Linux のみ）。クロスプラットフォームの答えにもなっていない
4. **HUD のワークロードに Rust の利点が効く箇所がない。** オーディオコールバック、ASR（フレームワーク内）、2 千件の fuzzy 検索、テキスト状態機械、AppKit UI。計算律速の箇所がない。GC 停止は Swift にも元々ない
5. **先行実装の量。** Swift 側は VoiceInk (★6.2k)、macparakeet、pindrop、TypeWhisper、Hex と FluidAudio で同じ問題を解いた読めるコードが揃う。GPUI 側は hex (★61) の 1 本
6. **`tauri-nspanel` #104「window level が高いと IME がブロックされる」**は日本語入力 HUD で致命的になりうる（open）

## 却下した案

| 案 | 却下理由 |
|---|---|
| Tauri | 上記 2・6。AppKit から逃れられず、ANE に届かない |
| GPUI 単体 | 上記 3・4・5。Swift を避けられるという前提が崩れている |
| GPUI + Swift サイドカー | 技術的には成立するが 2 言語・2 プロセスの境界を一人で保守することになる。「Rust で書きたい」が動機なら正当だが、ユーザーは M0 の実測で決めると選んだ |
| Electron | nonactivating panel が styleMask 後付けハックで公式 issue は closed as not planned。dmg 316MB (OpenWhispr) |

## 結果として受け入れるもの

- Rust で書けない。開発の楽しさという要件は満たさない可能性がある
- Windows / Linux ユーザーには届かない
- 「軽さ」の主戦場はシェルではなくモデル管理（モデル 478MB〜1.6GB vs シェル差 数十 MB）なので、この判断で軽さが決まるわけではない

## 見直しの条件

- Windows / Linux を出すと決めたとき → Tauri に振り直す（Handy が支払っている代償を支払う）
- M0 で Apple `SpeechTranscriber` を採らないと決まったとき → Swift 専用 API の優位が消えるので、GPUI + FluidAudio(Swift FFI) を再評価してよい

# ADR-013 本体をライブラリ + 薄い executable にし、検査は testTarget に統一する

- 状態: 承認
- 日付: 2026-09-07
- 関連: ADR-006（SwiftPM のみ）、[07 プロジェクト構成](../specs/07-project-structure.md)

## 文脈

v1.0.0 時点の `Package.swift` は 11 ターゲットで、本体に要るのは 4 つだった。残りは検査の実行物 3 本と M0 ベンチ 4 本。
検査が実行物になっている理由は、`Vox` が executableTarget で他ターゲットから import できず、SwiftPM の `testTarget` が使えないため。
これを回避するために「テストから見たい部分だけ切り出したライブラリ」（VoxHudSupport, VoxSettingsSupport）が生まれ、
`just test` は `swift run vox-*-tests` 7 本、`check.sh` 2 本、python 2 本を順に叩いて PASS を自前で印字していた。
ベンチは本体に依存しない（M0HarnessCore + FluidAudio のみ）にもかかわらず同じ package にいて、root に FluidAudio が見えていた。

参考にした構成は ara-parrot（依存ゼロの Engine ライブラリ / macOS 層の Core ライブラリ / 4 ファイルの executable / testTarget 55 本）。

## 決定

1. 本体を `VoxCore`（Foundation のみ）、`VoxApp`（macOS 層のライブラリ）、`Vox`（`main.swift` だけの executable）の 3 ターゲットにする。
   HudSupport / SettingsSupport は VoxApp に吸収する。
2. 検査は `testTarget` 2 本（`VoxCoreTests`, `VoxAppTests`）に統一し、Swift Testing で書く。`just test` は `swift test`。
   shell の検査は `Tests/Tooling` に残す。python の検査は本体から無くす。
3. M0 ベンチは `benchmarks/Package.swift` の別 package にする。root の `Package.swift` は外部依存を持たない。
4. VoxCore / VoxApp の中は機能フォルダで分ける（Transcript / Injection / Palette / Settings / Resident …）。
   「UI 非依存なら何でも」のフラットな箱には戻さない。

## 却下した案

- **executable のまま検査実行物を維持する**: 検査を 1 本足すたびにターゲットが増える。`swift test` が使えず、失敗の集計も自前になる。
- **ベンチを root の package に残し `path:` で `benchmarks/` に置く**: 目に見える場所は変わるが、FluidAudio の解決とビルドが本体に残る。
- **VoxCore を ara に倣って `VoxEngine` に改名する**: 役割は既に同じ。改名は差分を増やすだけ。
- **フォルダ分けを先にやる**: import 境界が無いまま並べ替えても、テストが実行物のままでは効果が出ない。順序は ベンチ分離 → ライブラリ化 → テスト統合。

## 移行

| 段階 | 内容 | 完了条件 |
|---|---|---|
| 1 | ベンチを `benchmarks/` の別 package へ | root の `Package.swift` に依存なし。`just bench-*` が動く。`just verify` 通過 |
| 2 | `VoxApp` ライブラリ化と機能フォルダ配置。HudSupport / SettingsSupport 吸収。`App.swift` の接続を coordinator に分割 | `Vox` が `main.swift` のみ。`just verify` 通過。検査件数が減らない |
| 3 | 検査を `testTarget` 2 本に統合 | `swift test` だけで全検査。`check.sh` と python 検査が消える。件数が減らない |

各段階は挙動を変えない。挙動を変えたくなったら別の変更にする。

## 見直しの条件

- 本体が外部 package に依存する必要が出たとき（例: 確定レーンに FluidAudio を使う M4）。その場合も依存先は VoxApp までで、VoxCore には入れない。
- テストが 2 ターゲットで遅くなったとき（`swift test` が 2 分を超える）。フォルダ単位のターゲット分割を検討する。

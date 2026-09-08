# 07 プロジェクト構成

リポジトリの目標構成と、各ディレクトリの責務。理由は [ADR-013](../adr/013-library-app-and-test-targets.md)。
最終確認日: 2026-09-07。状態: **移行完了**（`Tools/DocImages` だけ未実施。現状は末尾）。

## 目標

```
Package.swift            外部依存なし
Sources/
  VoxCore/               Foundation だけに依存する判定と変換。UI・プロセス起動・AppKit を持たない
    Transcript/          本文モデル、キャレット、フィラー除去、sigil 検出、確定位置
    Injection/           貼り付け前後の安全判定、自動 Enter、アクティベーション方針
    Palette/             検索対象の解釈、索引、ツリー、あいまい一致、パス表記、プレビュー読み取り
    Settings/            設定の形式と検証、ショートカット表記、権限チェックリストの状態
    Resident/            常駐の状態機械と表示文言
    Records/             履歴・計測レコードの直列化
    Process/             子プロセス実行、単調時計
  VoxApp/                macOS 層。AppKit / SwiftUI / AVFoundation / Speech / CoreGraphics を使う唯一の場所
    Session/             録音セッションの接続点（App.swift）。開始・確定・破棄の流れ
    Audio/               SpeechAnalyzer とマイク、音声診断
    Input/               ホットキー監視、貼り付け、入力欄の読み取り
    Hud/                 HUD パネルと本文エディタ
    Palette/             パレットのパネル・ビュー、対象フォルダの解決、索引の取得
    Settings/            設定画面、保存、マイク一覧、起動時の解決
    Resident/            メニューバー、操作ウィンドウ、ログイン項目、二重起動防止
    Support/             シェル実行、ログ経路、計測・履歴の書き込み
    Launch/              起動引数の解釈と起動手順
  Vox/                   main.swift だけ。VoxApp.Launch を呼ぶ
Tests/
  VoxCoreTests/          VoxCore の testTarget（Swift Testing）。フォルダは Sources 側と同じ
  VoxAppTests/           VoxApp の testTarget。オフスクリーン描画、貼り付け、設定、常駐、音声形式の検査
  Tooling/               scripts/ の隔離テスト（shell）
Tools/
  DocImages/             README 画像の生成（VoxApp を import する executable）
benchmarks/
  Package.swift          M0 ハーネス。FluidAudio はここだけが依存する
  Sources/               M0HarnessCore, VoxM0, VoxM0FactCheck, VoxM0LiveProbe
  Tests/                 M0HarnessCoreTests, BenchmarkReport（python）
  scripts/               prepare_jsut.py, prepare_m0_audio.sh, render_m0_results.py
  m0/                    manifest.example.tsv（音声・モデル・結果は Git 対象外）
scripts/                 配布と検査だけ: bundle-app, sign-app, make-dmg, notarize-dmg, validate-app, make-app-icon,
                         install.sh, lint, security, setup, render-palette-example.py
Resources/               Info.plist, entitlements, アイコン
docs/                    adr/ specs/ usage.md development.md MANUAL-VERIFICATION.md KNOWN-ISSUES.md
images/                  README の画面例（合成データ）と再生成の手順
.agents/skills/          vox-release, vox-setup, vox-change-docs
```

## 責務の線

| 線 | 規則 |
|---|---|
| VoxCore ↔ VoxApp | VoxCore は `import Foundation` のみ。プロセス起動の実行（`ProcessRunner`）は Foundation の範囲なので VoxCore に置くが、どのコマンドを叩くかは VoxApp が決める |
| VoxApp ↔ Vox | Vox（executable）は `main.swift` 1 ファイル。テストから import できるものはすべて VoxApp |
| Session ↔ 各 coordinator | `Session/App.swift` は録音セッションの流れ（開始・確定・破棄・貼り付け）と、それが同時に触る状態だけを持つ。パレット・設定・常駐は coordinator。行数を理由に `private` を落として分けない（見直しは確定レーン導入時） |
| 本体 ↔ benchmarks | 別 package。本体は benchmarks に依存せず、benchmarks も VoxCore に依存しない |
| Tests ↔ scripts | Swift の検査は `swift test`。shell の検査は `Tests/Tooling`。python の検査は benchmarks 側だけ |

## ファイル単位の対応（現状 → 目標）

### Sources/Vox → Sources/VoxApp

| 目標 | 現在のファイル |
|---|---|
| Session/App.swift | App.swift（接続点。段階 2 で Recording / Palette / Injection の coordinator に分ける） |
| Audio/ | SpeechLane.swift, AudioCaptureDiagnostics.swift |
| Input/ | HotkeyMonitor.swift, Injector.swift, AccessibleInput.swift |
| Hud/ | HudPanel.swift, VoxHudSupport/HudTranscript.swift |
| Palette/ | PalettePanel.swift, PaletteView.swift, PaletteTargetResolver.swift, FileIndexer.swift |
| Settings/ | VoxSettingsSupport/*（SettingsView, SettingsController, SettingsModel, SettingsStore, SettingsStartup, MicrophoneDevices） |
| Resident/ | StatusItemController.swift, AppControlsWindow.swift, LoginItemService.swift, AppInstanceLock.swift |
| Support/ | Shell.swift, AppLogRouter.swift, Metrics.swift, History.swift |
| Launch/ | main.swift の引数解釈（`VoxOptions`, `parseOptions`, usage）と起動手順 |

### Sources/VoxCore（フォルダ分け）

| 目標 | 現在のファイル |
|---|---|
| Transcript/ | TranscriptBuffer, TranscriptCaret, FillerPass, SigilTrigger, AnalyzerFinalizePoint, SpeechAssetReadiness |
| Injection/ | InjectionSafety, AutoEnter, TerminalAutoEnter, ActivationPolicy |
| Palette/ | PaletteTarget, PaletteSigil, FileIndex, FileTree, FuzzyMatch, FilePathFormat, BoundedFileReader |
| Settings/ | HotkeySettings, HotkeyBinding, SettingsPresentationState, SetupPermissions |
| Resident/ | ResidentPolicy |
| Records/ | HistoryRecord, MetricsRecord |
| Process/ | ProcessRunner, MonotonicClock |

### Tests

| testTarget | フォルダ |
|---|---|
| VoxCoreTests（VoxCore に依存） | Transcript/, Palette/, Injection/, Records/, Process/, Resident/, Settings/ と共有の Expectations.swift |
| VoxAppTests（VoxApp に `@testable` で依存） | Settings/, Resident/, Hud/, Injection/, Audio/, Palette/ |
| Tooling/ | shell の検査（nix-sdk、pre-commit、package、署名） |
| benchmarks/Tests | Tests/M0HarnessCoreTests, Tests/BenchmarkReport |

## 現状（2026-09-07。移行完了）

- ターゲットは 6 つ: `VoxCore` / `VoxApp` / `Vox` / `VoxDocImages` と testTarget 2 本。検査用の executableTarget は無い
- 機能フォルダは上の表どおり（`Sources/VoxCore` と `Sources/VoxApp` の直下に `.swift` は無い）
- FluidAudio 依存は benchmarks だけ
- 検査の入口は `just test` = `Tests/Tooling/nix-sdk-check.sh` + `swift test --no-parallel` の 2 本
- `VoxApp` に `@_spi(Testing)` は無い（testTarget の `@testable import` で足りる）
- `Tools/` はまだ作っていない。`VoxDocImages` は `Sources/VoxDocImages` のまま

移行は [ADR-013](../adr/013-library-app-and-test-targets.md) の段階 1〜3 で行い、各段階で `just verify` を通した。

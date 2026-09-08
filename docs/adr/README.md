# ADR — 技術判断の記録

[`docs/specs/`](../specs/README.md) は「何がどうなっているか」の記録。ここは「**なぜそう決めたか、何を却下したか、何が起きたら見直すか**」を残す場所。
次のモデルや人が同じ判断をやり直さずに済むことが目的。

## 書き方

- ファイル名は `NNN-slug.md`。番号は採番順で、並び替えない
- 状態は `提案` / `承認` / `廃止` / `置換 (→ NNN)` のいずれか
- 「見直しの条件」を必ず書く。条件が起きていないのに ADR を蒸し返さない
- 却下した案は理由付きで残す。後から「なぜ選ばなかったか」を聞かれるのは却下案のほう

## 一覧

| # | 題 | 状態 | 日付 |
|---|---|---|---|
| [001](001-macos-only-native-swift.md) | macOS 専用・native Swift をシェルにする | 承認 | 2026-09-01 |
| [002](002-two-lane-transcription.md) | 速報と確定の二段構成。目的は書き換えの排除 | 承認 | 2026-09-01 |
| [003](003-confirm-lane-parakeet-ja.md) | 確定レーンに parakeet-0.6b-ja-coreml | 承認 | 2026-09-01 |
| [004](004-toggle-recording-batch-insert.md) | 録音はトグル、挿入は終了時に一括 | 承認 | 2026-09-01 |
| [005](005-command-palette-sigil.md) | コマンドパレットは単一ホットキー + sigil | 承認 | 2026-09-01 |
| [006](006-swiftpm-only-nix-devshell.md) | SwiftPM のみ。nix は devShell とベンチ環境だけ | 承認 | 2026-09-01 |
| [007](007-latency-measurement-method.md) | 初出遅延はファイル給餌 + `.fastResults` で測る | 承認 | 2026-09-02 |
| [008](008-reference-text-convention.md) | 正解テキストの表記規約 | 承認 | 2026-09-01 |
| [009](009-text-insertion-promise-pasteboard.md) | テキスト挿入は promise pasteboard 方式 | 提案 | 2026-09-01 |
| [010](010-speed-metric-axis-a-apple.md) | 「速さ」の看板を発話終了→挿入完了に移し、速報は Apple | 承認 | 2026-09-02 |
| [011](011-hud-edit-mode-and-context-cwd.md) | HUD の編集モードと、挿入先・検索対象をトグル ON 時の前面アプリで決める | 提案 | 2026-09-02 |
| [012](012-filler-removal-rule-based.md) | フィラー除去は規則ベースの後処理。LLM 整形は入れない | 提案 | 2026-09-02 |
| [013](013-library-app-and-test-targets.md) | 本体をライブラリ + 薄い executable にし、検査は testTarget に統一する | 承認 | 2026-09-07 |
| [014](014-auto-enter-readability-decides.md) | 自動 Enter は読み返せるかで自動判定し、読めないときの送信だけを設定にする | 承認 | 2026-09-08 |

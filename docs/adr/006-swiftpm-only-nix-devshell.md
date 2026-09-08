# ADR-006: SwiftPM のみでビルドし、nix は devShell とベンチ環境だけを持つ

- 状態: **承認**
- 日付: 2026-09-01
- 関連: 設計書 §0 決定 7・8、`flake.nix`

## 文脈

開発機に Xcode が入っていない（Command Line Tools のみ。Swift 6.3、target `arm64-apple-macosx26.0`）。
ユーザーは nix で環境を管理したい。

## 判断 1: SwiftPM のみ。`.xcodeproj` を作らない

**理由**: Xcode 不要で今日からビルドできる。macparakeet が同じ問題領域（FluidAudio + Speech）で SwiftPM 直を実証済み。差分がテキストで見やすく、nix との相性もよい。

**代償**: SwiftUI プレビューが使えない。配布時の公証（`xcrun notarytool`）は Xcode 同梱なので、OSS 公開で他人に配る段階で Xcode が必要になる。

**運用上の注意**: 素の `swift build` は FluidAudio 0.15.0 の `FluidAudioCLI` ターゲットが Swift コンパイラの型推論タイムアウトで落ちる（上流の不具合）。必ず `--product` を指定する。`justfile` は対応済み。

## 判断 2: nix は devShell + M0 ベンチ環境のみ。Swift コンパイラとアプリビルドは対象外

**理由**: nixpkgs の darwin 版 `swift` は Apple framework へのリンクで詰まりやすく、システムの Swift（target SDK と一致）を使うほうが確実。`packages.default` でアプリを包んでも、得られるのは「`swift build` という 1 コマンドの包装」だけで、darwin sandbox との衝突リスクを負う価値がない。一方、ベンチの評価環境（CER 計算・データセット取得）は再現性の価値が高い。

**実装上の判断**:
- `aarch64-darwin` のみ（macOS 専用に合わせ `flake-utils` も足さない）
- `fsspec` の `test_expiry` が時刻依存で不安定なため `doCheck = false`。`huggingface-hub` の依存で JSUT 取得に必要なので外せない
- `swiftformat` / `swiftlint` は nixpkgs に attribute はあるが darwin での `nix develop` 通過を確認できず外した。入れるなら `nix build` が通ることを先に確認する
- グローバル `~/.config/git/ignore` が `flake.nix` を除外していたため、リポジトリの `.gitignore` に `!flake.nix` / `!flake.lock` を追加

## 却下した案

| 案 | 却下理由 |
|---|---|
| Xcode プロジェクト | Xcode の DL に数十 GB。`.xcodeproj` は nix の管理外になり、flake の役割が周辺ツールだけになる |
| ビルドまで nix で包む | 上記。リスクに対して得るものが小さい |

## 見直しの条件

- OSS 公開で公証が必要になったとき → Xcode を入れる。ただし `.xcodeproj` は作らず `swift build` + `codesign` + `notarytool` で通す道を先に試す
- nixpkgs の darwin 版 swift が安定し、Apple framework リンクが問題なく通るようになったとき

# README の画面例

- `settings.png`: 本体と同じ `SettingsView` を合成設定・架空のマイク情報でオフスクリーン描画したもの。
- `palette-tree.png`: 本体の `PaletteView` を架空のプロジェクト・ファイル・プレビュー本文で描画。索引取得や実ファイルのプレビューは行わない。
- `hud-example.png`: 本体と同じ `TranscriptEditor` に合成文と架空パスを入れ、周囲の HUD を再現したイメージ。実行中画面のキャプチャではない。

録音・入力監視・前面アプリの取得・スクリーンキャプチャは行わない。個人の設定ファイル・発話履歴を読み込まない。キーは変更例として cmd+opt+space を表示し、製品の既定値とは区別する。

再生成:

```sh
swift run vox-doc-images
python3 scripts/render-palette-example.py
```

出力先の変更は `swift run vox-doc-images /path/to/output`。実装は `Sources/VoxDocImages/main.swift`。
アイコンは提供されたコンセプト画像から抽出した透過 PNG を採用した。画像生成後に alpha 0〜255 を確認済み。元ファイルと由来は [Resources](../Resources/README.md) を参照。

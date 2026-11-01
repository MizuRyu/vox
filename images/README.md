# README の画面例

- `settings.png`: 本体と同じ `SettingsView` を合成設定・架空のマイク情報・架空の辞書（2 行）でオフスクリーン描画したもの。
- `palette-tree.png`: 本体の `PaletteView` を架空のプロジェクト・ファイル・プレビュー本文で描画。索引取得や実ファイルのプレビューは行わない。
- `hud-example.png`: 本体と同じ `TranscriptEditor` に合成文と架空パスを入れ、周囲の HUD を再現したイメージ。実行中画面のキャプチャではない。
- `vox-demo-ja.mp4` / `.gif` / `.png`: 日本語版の25秒紹介動画・README用GIF・再生前の静止画。
- `vox-demo-en.mp4` / `.gif` / `.png`: 英語版。同じ日本語音声入力の操作を、英語の説明文で紹介する。

録音・入力監視・前面アプリの取得・スクリーンキャプチャは行わない。個人の設定ファイル・辞書・発話履歴を読み込まない。キーは変更例として cmd+opt+space を表示し、製品の既定値とは区別する。

再生成:

```sh
swift run vox-doc-images
python3 scripts/render-palette-example.py
```

出力先の変更は `swift run vox-doc-images /path/to/output`。実装は `Sources/VoxDocImages/main.swift`。
アイコンは提供されたコンセプト画像から抽出した透過 PNG を採用した。画像生成後に alpha 0〜255 を確認済み。元ファイルと由来は [Resources](../Resources/README.md) を参照。

紹介動画は別リポジトリ`product-movie`の`examples/vox/movie.json`から生成する。標準の配置はVoxと同じ親フォルダの`../product-movie/`。ツールのREADMEに必要な環境と編集手順を記載している。

```sh
uv run --no-project python ../product-movie/build.py --config ../product-movie/examples/vox/movie.json --output images
uv run --no-project python ../product-movie/build.py --config ../product-movie/examples/vox/movie.json --output images --check
```

合成文・架空の入力欄とファイルを使い、音楽も波形から合成する。

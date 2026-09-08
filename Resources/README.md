# アイコン

`VoxIcon.png` は利用者から提供された「声からテキストへ変わるリボン」のコンセプト画像から、ロゴ部分を画像生成ツールで抽出した透過 PNG です。README とアプリで同じ画像を使います。配布用 ICNS は `scripts/make-app-icon` で生成します。

## UI の状態アイコン

セットアップの許可済み表示は macOS 標準の [SF Symbols](https://developer.apple.com/sf-symbols/) の `checkmark.circle.fill`、未完了の手順は `1.circle` / `2.circle` / `3.circle` を使います。丸とチェックを一体のシンボルとして描画し、文字のベースラインや背景レイヤーに起因する位置ずれを避けます。AppKit のシンボルAPIから取得し、画像ファイルや追加ライブラリは同梱しません。

UI アイコンを追加する際も用途に合う既存素材を優先し、同じ画面内ではシリーズを揃えます。製品・サービスのロゴが必要な場合は、利用者が挙げた [gilbarbara/logos](https://github.com/gilbarbara/logos) を参照先にします。このコレクションはブランドの SVG ロゴを扱っています。

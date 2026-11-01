# 紹介動画の再生成

`just movie`で日本語版・英語版のMP4、README用GIF、再生前の静止画を生成する。`just movie ja` / `just movie en`で片方だけ更新できる。表示確認は`preview.html`を既定のブラウザーで開く。

独立したSwiftPMパッケージとして、macOSのSwift・AppKit・AVFoundationと、Python・ffmpegを使う。`nix develop`でuvとffmpegを含む開発ツールを揃え、SwiftはXcodeのものを使う。ライブラリの追加、外部API、Vox本体の起動は不要。

| 変更するもの | 保存先 |
|---|---|
| 製品名、ロゴ、リポジトリURL、文言、入力例、場面の開始時刻 | `movie.json` |
| 各場面の配置と動き | `main.swift`の6つの`*Scene`関数 |
| BGM | `music.py`。波形から合成する。音源や操作音のサンプルは使わない |
| 書き出しと検査 | `build.py` |

文言は日本語版と英語版を同じJSONに持つ。英語版が紹介するのも日本語の音声入力で、アプリ内の表示と入力例は日本語のまま。画面は合成データで描いた入力イメージであり、実機録画や処理時間の測定映像ではない。

文字はCoreTextで直接描画する。フレームごとに画面やウィンドウを作らず、指定した時刻の画像を動画へ書き込む。

## 生成物と検査

`images/<slug>-demo-<locale>.mp4` / `.gif` / `.png`をGitで管理する。MP4は1080p・30fps・音楽付き、GIFは800×450・10fps・無音。中間ファイル・実行ログ・検査結果は`z-ai/YYYY-MM-DD-product-movie/`に置く。

出力先にコピーする前に、MP4の全フレームと音声、GIFのフレーム数・長さを検査する。`just movie-check`で保存済みの素材を再検査できる。失敗時は`NG`とログの場所を表示する。

同じソース・文言・時刻から同じ構成を再生成できる。OSの書体・SF Symbols・動画エンコーダーによる差があるため、別の環境でファイルのバイト列まで一致する保証はない。

## 別のOSSで使う

このフォルダを別のリポジトリの`Tools/ProductMovie/`へコピーし、`movie.json`の製品名・ロゴ・文言を差し替える。録音HUDやファイル検索などVox固有の画面は、`main.swift`の場面描画をその製品の操作に合わせて直す。音楽・時間指定・日英の書き出し・GIF化・検査の手順は共通で使える。

```sh
uv run --no-project python Tools/ProductMovie/build.py
uv run --no-project python Tools/ProductMovie/build.py --locale en
uv run --no-project python Tools/ProductMovie/build.py --check
```

素材を変える際も、実際の利用者の発話・履歴・ファイルパス・他アプリ画面は使わず、合成した例を用意する。

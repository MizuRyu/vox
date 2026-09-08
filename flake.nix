{
  description = "vox — ローカル完結の日本語音声入力 HUD。開発シェルと M0 ベンチ環境。";

  # 役割の境界は docs/adr/006-swiftpm-only-nix-devshell.md で確定している。
  #
  #   持つもの   : 開発の周辺ツール、M0 ベンチの評価環境 (CER 計算・データセット取得)
  #   持たないもの: Swift コンパイラ、アプリのビルド
  #
  # Swift を nix に持たせない理由: nixpkgs の darwin 版 swift は Apple framework への
  # リンクで詰まりやすく、システムの Swift (6.3 / target arm64-apple-macosx26.0) を
  # 使うほうが確実。ビルドは `swift build`。
  #
  # アプリビルドを packages.default にしない理由: darwin の sandbox と Apple framework
  # リンクで詰まるリスクが高く、得られるのは「swift build という 1 コマンドの包装」だけ。

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # 決定 1 により macOS 専用。他システムは意図的に定義しない。
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      # fsspec の test_expiry が時刻依存で不安定 (assert が μ 秒差で落ちる) なため
      # チェックを外す。fsspec は huggingface-hub の依存で、JSUT の取得
      # (benchmarks/scripts/prepare_jsut.py の hf_hub_download) に必要なので外せない。
      # 実害のある壊れ方ではなく flaky test なので doCheck の無効化で対処する。
      python = pkgs.python312.override {
        packageOverrides = _final: prev: {
          fsspec = prev.fsspec.overridePythonAttrs (_: { doCheck = false; });
        };
      };

      # M0 ベンチの評価側。推論は Swift 側 (システム Swift) で走らせ、
      # ここでは CER 計算とデータセット取得だけを担う。
      benchPython = python.withPackages (ps: [
        ps.jiwer # CER / WER 計算
        ps.numpy
        ps.soundfile # 音声の読み書き
        ps.pandas
        ps.tabulate # 結果表の整形
        ps.huggingface-hub # JSUT basic5000 の取得
      ]);

      # mkShell の stdenv が提供する xcbuild 版 xcrun は Nix の SDK を選ぶ。
      # Apple Swift と同じ Xcode の SDK を選べるよう、Apple の xcrun を優先する。
      appleXcrun = pkgs.writeShellScriptBin "xcrun" ''
        exec /usr/bin/xcrun "$@"
      '';
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        name = "vox";

        packages = [
          appleXcrun
          benchPython
          pkgs.ffmpeg # 音声を 16kHz mono へ正規化
          pkgs.just # タスクランナー (justfile)
          pkgs.jq
          pkgs.fd
          pkgs.ripgrep
          pkgs.gitleaks
          pkgs.semgrep
          pkgs.lefthook
          pkgs.swiftlint
          pkgs.shellcheck
        ];

        # 意図的に外したもの:
        #
        #   swift-format
        #     既存コードに多数の差分があり、現時点で検査を必須化すると全変更を止める。
        #     一括整形はせず、SwiftLint の高シグナルな規則だけを scripts/lint で使う。
        #
        #   swift / swiftpm
        #     上記のとおりシステムの Swift を使う。

        shellHook = ''
          # mkShell が注入する Nix SDK を、現在 xcode-select で選択されている
          # Xcode の値へ置き換える。Xcode の配置や SDK version は固定しない。
          unset SDKROOT DEVELOPER_DIR
          export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
          export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

          echo "vox devShell"
          echo "  swift : $(swift --version 2>/dev/null | head -1 || echo '見つからない')"
          echo "  python: $(python3 --version)"
          echo ""
          echo "  just --list   でタスク一覧"
          echo "  just build    で本体をビルド (システムの Swift を使う)"
          echo "  just setup    で Git hook を設定"
        '';
      };

      # `nix flake check` が devShell だけを見るように、他の output は定義しない。
      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}

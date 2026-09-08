version := `tr -d '[:space:]' < VERSION`

[private]
default:
    @just --list

# 開発ツールを確認し、Lefthook を現在の checkout に入れる。
setup:
    scripts/setup

build:
    swift build -c release --product Vox

test:
    Tests/Tooling/nix-sdk-check.sh
    swift test --no-parallel

# Swift / shell / Python の軽量な静的検査。ファイルは変更しない。
lint:
    scripts/lint --worktree

# 作業ツリー、index、存在する場合は全履歴を秘密・静的ルールで検査する。
security:
    scripts/security --all

# pre-commit と同じ隔離テストを一時 Git repository で実行する。
tooling-test:
    Tests/Tooling/security-hook-tests.sh
    Tests/Tooling/package-tests.sh
    Tests/Tooling/development-signing-tests.sh

# ビルドやアプリ起動を含まない開発用チェック。
check: security lint tooling-test

verify: check build test

# dist/Vox-{{version}}.app と .dmg（+ .sha256）を作る。署名は環境で決まる。
bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    app="dist/Vox-{{version}}.app"
    dmg="dist/Vox-{{version}}.dmg"
    development_identity="${XDG_CONFIG_HOME:-$HOME/.config}/vox/development-signing-identity"
    if [[ -n "${VOX_SIGNING_IDENTITY:-}" ]]; then
        printf '署名: Developer ID Application（公開配布向け）\n'
        # sign-app は入出力が別で、どちらも既存を置き換えない。
        staging="dist/.Vox-{{version}}-unsigned.app"
        rm -rf "$staging" "$app"
        scripts/bundle-app --adhoc --output "$staging"
        scripts/sign-app "$staging" "$app"
        rm -rf "$staging"
    elif [[ -f "$development_identity" ]]; then
        printf '署名: Apple Development（手元の更新。権限を引き継げる）\n'
        scripts/bundle-app --development --allow-dirty
    else
        printf '署名: ad-hoc（診断用。更新のたびに権限を許可し直す必要がある）\n'
        scripts/bundle-app --adhoc --allow-dirty
    fi
    rm -f "$dmg" "$dmg.sha256"
    scripts/make-dmg "$app" "$dmg"

# 作った .app を /Applications に入れ替える。Vox が起動中なら何もしない。
install: bundle
    #!/usr/bin/env bash
    set -euo pipefail
    if pgrep -x Vox >/dev/null; then
        printf 'just install: Vox が起動中です。Vox を終了してからやり直してください。\n' >&2
        exit 1
    fi
    rm -rf /Applications/Vox.app
    cp -R "dist/Vox-{{version}}.app" /Applications/Vox.app
    xattr -dr com.apple.quarantine /Applications/Vox.app
    printf 'Installed /Applications/Vox.app\n'

uninstall:
    rm -rf /Applications/Vox.app

# Apple への送信を伴う明示操作。署名 identity と notary profile を環境から渡す。
notarize input output:
    scripts/notarize-dmg {{input}} {{output}}

# タグ・push・dmg 付き GitHub Release をワンセットで作る。NOTES は手書きのリリースノート（.agents/skills/vox-release）。
release notes:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f "{{notes}}" ]] || { printf 'just release: リリースノートがありません: {{notes}}\n' >&2; exit 64; }
    git diff --quiet && git diff --cached --quiet || { printf 'just release: 作業ツリーがクリーンではありません\n' >&2; exit 1; }
    just verify
    git tag -a "v{{version}}" -m "vox v{{version}}"
    git push origin main v{{version}}
    just bundle
    gh release create v{{version}} \
        "dist/Vox-{{version}}.dmg" "dist/Vox-{{version}}.dmg.sha256" \
        --title "vox v{{version}}" --notes-file "{{notes}}"

# ベンチは別 package（ADR-013）なので verify には含めない。
bench-test:
    swift run --package-path benchmarks m0-core-tests
    python3 -m unittest discover -s benchmarks/Tests/BenchmarkReport -v

fact-speech:
    swift run --package-path benchmarks vox-m0-fact-check speech

fact-events seconds="10":
    swift run --package-path benchmarks vox-m0-fact-check events --seconds {{seconds}}

# manifest の audio 相対パスは CWD ではなく manifest のディレクトリを基準に解決する。
bench-run engine manifest output *args:
    swift run --package-path benchmarks -c release vox-m0 benchmark --engine {{engine}} --manifest {{manifest}} --output {{output}} {{args}}

bench-normalize input output:
    benchmarks/scripts/prepare_m0_audio.sh {{input}} {{output}}

bench-jsut output="benchmarks/m0/jsut" limit="5000":
    python benchmarks/scripts/prepare_jsut.py --output-dir {{output}} --limit {{limit}}

bench-report inputs="benchmarks/m0/results/*.jsonl":
    python benchmarks/scripts/render_m0_results.py --input {{inputs}} --document benchmarks/m0/results/m0-results.md

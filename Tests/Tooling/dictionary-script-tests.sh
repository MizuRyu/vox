#!/usr/bin/env bash
# vox-add-dictionary の scripts/dictionary.py を合成データで検査する。
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$project_root/.agents/skills/vox-add-dictionary/scripts/dictionary.py"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/vox-dictionary-script-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass_count=0
pass() { pass_count=$((pass_count + 1)); }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
mode_of() { python3 -c 'import os, sys; print(format(os.lstat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"; }

data="$temporary_root/data"
mkdir -p "$data"
cat >"$data/history.jsonl" <<'JSONL'
{"schema_version":1,"raw_text":"ゾルテックでひみつのほんぶんを書く","inserted":true}
{"schema_version":1,"raw_text":"ゾルテックとクワイエルを並べる","inserted":true}
{"schema_version":1,"raw_text":"ゾルテックにクワイエルーを足す","inserted":true}
{"schema_version":1,"raw_text":"クワイエルとピンゴラとピンゴラ、ソロ","inserted":true}
not json
{"schema_version":1,"raw_text":null}
JSONL
printf 'zoltech zoltech Zoltech quiel pingola pingola blorf blorf blorf a\n' >"$data/typed.txt"
printf 'ピンゴラ\tpingola\nクワイエル\tquiel\n' >"$data/dictionary.tsv"

# suggest: 語と件数、長音のまとめ、英字の対応、登録済みの印。本文は出さない。
out="$(python3 "$script" suggest --dir "$data" --typed "$data/typed.txt")"
contains "$out" '| ゾルテック | 3 | zoltech | 3 |' 'suggest counts and maps'
contains "$out" '| クワイエル / クワイエルー | 3 | quiel | 1 | 一部（クワイエル） |' 'suggest merges long vowel'
contains "$out" '| ピンゴラ | 2 | pingola | 2 | 済 |' 'suggest marks registered'
contains "$out" '| blorf | 3 |' 'suggest lists typed words without katakana'
lacks "$out" 'ソロ' 'suggest honours default min-count'
lacks "$out" 'ひみつ' 'suggest hides body text'
lacks "$out" '書く' 'suggest hides body text'
lacks "$out" '| a |' 'suggest drops one-letter words'
pass
out="$(python3 "$script" suggest --dir "$data" --min-count 1)"
contains "$out" '| ソロ | 1 |' 'suggest honours --min-count'
pass
if python3 "$script" suggest --dir "$temporary_root/missing" >/dev/null 2>&1; then
  fail 'suggest without history must fail'
fi
pass

# add: 無ければテンプレート付きで 0600 で作る。テンプレートは DictionaryStore.swift と同じ文面。
fresh="$temporary_root/fresh"
python3 "$script" add --dir "$fresh" $'ゾルテック\tzoltech' $'ソロ\t' >/dev/null
[[ "$(mode_of "$fresh/dictionary.tsv")" == 600 ]] || fail 'add creates 0600'
[[ "$(mode_of "$fresh")" == 700 ]] || fail 'add creates the directory as 0700'
swift_template="$(perl -0ne 'print $1 if /static let template = """\n(.*?)\n\s*"""/s' \
  "$project_root/Sources/VoxApp/Settings/DictionaryStore.swift" | perl -pe 's/^    //; s/\\t/\t/g')"
[[ -n "$swift_template" ]] || fail 'template not found in DictionaryStore.swift'
expected="$swift_template"$'\n'$'ゾルテック\tzoltech\nソロ\t'
[[ "$(<"$fresh/dictionary.tsv")" == "$expected" ]] || fail 'add writes the same template as the app'
pass

# add: タブ 1 つ、左辺あり、# で始まらない。1 つでも不正なら何も書かない。
before="$(<"$fresh/dictionary.tsv")"
for bad in 'タブなし' $'a\tb\tc' $'\tempty-left' $'#コメント\tx' $'改\n行\tx' $'  \tx'; do
  if python3 "$script" add --dir "$fresh" $'クワイエル\tquiel' "$bad" 2>/dev/null; then
    fail "add must reject: $bad"
  fi
done
[[ "$(<"$fresh/dictionary.tsv")" == "$before" ]] || fail 'rejected add must not write'
pass

# add: 既存の左辺と、引数どうしの重複は行番号つきで拒否する。
err="$(python3 "$script" add --dir "$fresh" $'ゾルテック\tother' 2>&1)" && fail 'duplicate must fail'
contains "$err" '7 行目' 'duplicate reports the line number'
if python3 "$script" add --dir "$fresh" $'ピンゴラ\ta' $'ピンゴラ\tb' 2>/dev/null; then
  fail 'duplicate arguments must fail'
fi
[[ "$(<"$fresh/dictionary.tsv")" == "$before" ]] || fail 'duplicate add must not write'
pass

# add: 既存ファイルは末尾に追記するだけ。改行で終わらないファイルは行を分ける。権限は 0600 にする。
kept="$temporary_root/kept"
mkdir -p "$kept"
printf '# 手で書いたメモ\nフー\tfoo\n壊れた行' >"$kept/dictionary.tsv"
chmod 644 "$kept/dictionary.tsv"
python3 "$script" add --dir "$kept" $'ピンゴラ\tpingola' >/dev/null
[[ "$(<"$kept/dictionary.tsv")" == $'# 手で書いたメモ\nフー\tfoo\n壊れた行\nピンゴラ\tpingola' ]] \
  || fail 'add appends without rewriting other lines'
[[ "$(mode_of "$kept/dictionary.tsv")" == 600 ]] || fail 'add sets 0600 on an existing file'
pass

# add: 64KiB を超えるなら書かない。リンクは辿らない。
large="$temporary_root/large"
mkdir -p "$large"
perl -e 'print "#" x 65530, "\n"' >"$large/dictionary.tsv"
if python3 "$script" add --dir "$large" $'ピンゴラ\tpingola' 2>/dev/null; then
  fail 'add must keep the file within 64KiB'
fi
linked="$temporary_root/linked"
mkdir -p "$linked"
ln -s "$kept/dictionary.tsv" "$linked/dictionary.tsv"
if python3 "$script" add --dir "$linked" $'ソロ\tsolo' 2>/dev/null; then
  fail 'add must not follow a symbolic link'
fi
pass

# list: 登録済みの行だけを「左 → 右」で。コメントは出さず、壊れた行は行番号で知らせる。
out="$(python3 "$script" list --dir "$kept")"
contains "$out" 'フー → foo' 'list shows entries'
contains "$out" 'ピンゴラ → pingola' 'list shows appended entries'
contains "$out" '3 行目' 'list reports broken lines'
lacks "$out" 'メモ' 'list hides comments'
out="$(python3 "$script" list --dir "$fresh")"
contains "$out" 'ソロ → （削除）' 'list shows empty right side as deletion'
pass

printf 'dictionary-script-tests: %d passed\n' "$pass_count"

#!/usr/bin/env bash
# vox-input-habits の scripts/habits.py を合成データで検査する。
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$project_root/.agents/skills/vox-input-habits/scripts/habits.py"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/vox-habits-script-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass_count=0
pass() { pass_count=$((pass_count + 1)); }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

# 2026-08（1 件、音声らしくない）と 2026-09（4 件、うち音声らしい 2 件）。時刻は 2026-08-15 / 2026-09-15 の正午 UTC。
claude="$temporary_root/claude.jsonl"
codex="$temporary_root/codex.jsonl"
cat >"$claude" <<'JSONL'
{"display":"ひみつのぶんしょうを直してほしいかな","timestamp":1786795200000}
{"display":"えっと、なんか設定がおかしい気がするんだよね。ちょっと見てもらっていいですか","timestamp":1789473600000}
{"display":"/clear","timestamp":1789473600000}
{"display":"短い","timestamp":1789473600000}
{"display":"[Pasted text #1 +20 lines]","timestamp":1789473600000}
not json
JSONL
cat >"$codex" <<'JSONL'
{"text":"まあ、うーん、静かな部屋でなんかな、と思った。これでいいでしょうか","ts":1789473600}
{"text":"このキーは本番用のもので sk-abcdefghijklmnopqrstuv で、確認でしょ？","ts":1789473600}
{"text":"かなり確かな話で、何もかも終わった","ts":1789473600}
JSONL

out="$(python3 "$script" report --claude "$claude" --codex "$codex")"
# 材料: スラッシュ・短すぎ・貼り付けの印・壊れた行を除いて 5 件。音声らしいのは言いよどみ 2 回以上の 2 件。
contains "$out" '| 日本語の発話 | 5 |' 'report counts kept messages'
contains "$out" '| 音声入力らしい | 2 |' 'report counts voice-like messages'
contains "$out" '| 2026-08 | 1 | 0 | 0% |' 'monthly share uses the same filler list'
contains "$out" '| 2026-09 | 4 | 2 | 50% |' 'monthly share uses the same filler list'
pass

# かな: 「なんかな」「静かな」「確かな」「かなり」は数えない。文末の 1 件だけ。
contains "$out" '| かな | 1 |' 'かな excludes なんかな / 静かな / 確かな / かなり'
# かも: 「何もかも」は数えない。
contains "$out" '| かも | 0 |' 'かも excludes 何もかも'
# でしょ: 丁寧な「でしょうか」は確認の「でしょ」と分ける。
contains "$out" '| でしょ（確認） | 1 |' 'でしょ excludes でしょうか'
contains "$out" '| でしょうか（丁寧な依頼・質問） | 1 |' 'でしょうか is counted on its own'
contains "$out" '| よね | 1 |' 'よね counted'
contains "$out" '| 気がする | 1 |' '気がする counted'
contains "$out" '| 〜してもらっていいですか | 1 |' 'request form counted'
pass

# 平均文字数: 音声らしい 2 件と、それ以外 3 件を別々に（以前は変数の上書きで壊れていた）。
contains "$out" '| 音声入力らしい | 2 | 36 |' 'average length of voice-like messages'
contains "$out" '| それ以外 | 3 | 27 |' 'average length of the other messages'
pass

# 本文は出さない。語と件数だけ。
lacks "$out" 'ひみつ' 'report hides body text'
lacks "$out" '部屋' 'report hides body text'
lacks "$out" 'sk-abc' 'report hides secrets'
pass

# samples: 抜粋は短い窓だけ、秘密は伏せる。知らない語は拒む。
out="$(python3 "$script" samples 'でしょ（確認）' --claude "$claude" --codex "$codex")"
contains "$out" '[伏字]' 'samples redact secrets'
lacks "$out" 'sk-abc' 'samples redact secrets'
lacks "$out" 'このキーは' 'samples keep a short window'
pass
err="$(python3 "$script" samples 'ないしょ' --claude "$claude" --codex "$codex" 2>&1)" && fail 'unknown term must fail'
contains "$err" 'かな' 'unknown term lists the known terms'
pass

# json: 同じ数字を機械向けに。
out="$(python3 "$script" report --json --claude "$claude" --codex "$codex")"
python3 -c 'import json, sys; d = json.loads(sys.argv[1]); assert d["voice_like"] == 2 and d["endings"]["かな"]["total"] == 1' "$out" \
  || fail 'json report has the same numbers'
pass

# 材料が無ければ止まる。片方だけなら残りで数える。
err="$(python3 "$script" report --claude "$temporary_root/none" --codex "$temporary_root/none2" 2>&1)" && fail 'no history must fail'
lacks "$err" "$temporary_root" 'errors do not print the storage path'
out="$(python3 "$script" report --claude "$claude" --codex "$temporary_root/none2")"
contains "$out" '| 日本語の発話 | 2 |' 'one history is enough'
pass

printf 'habits-script-tests: %d passed\n' "$pass_count"

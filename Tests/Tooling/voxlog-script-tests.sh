#!/usr/bin/env bash
# vox-debug の scripts/voxlog.py を合成ログで検査する。
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$project_root/.agents/skills/vox-debug/scripts/voxlog.py"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/vox-voxlog-script-tests.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass_count=0
pass() { pass_count=$((pass_count + 1)); }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2' in: $1"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

data="$temporary_root/data"
mkdir -p "$data/logs"
# 4 回の録音: 成功 / 挿入先の変化 / 破棄 / 開始の失敗。録音の外の行も混ぜる。
cat >"$data/logs/vox.log" <<'LOG'
permissions ax_process_trusted=true listen_event_access=true post_event_access=true
index_rebuilt scope=changes count=1 ms=3 files=10 root=/tmp/example/outside
hotkey toggle_pressed at_ms=1000
target_app fixed=com.example.editor
audio_input device="Example Mic" selection=automatic device_id=42 transport=built_in
analyzer_started at_ms=1100
result index=1 at_ms=1200 is_final=false committed_length=0 tentative_length=3
result index=2 at_ms=1300 is_final=true committed_length=5 tentative_length=0
attachment_saved kind=png bytes=10 path=/tmp/example/x.png
result index=3 at_ms=1400 is_final=false committed_length=5 tentative_length=2
palette_target source=terminal root=/tmp/example/repo
hotkey toggle_pressed at_ms=2000
final_text 合成の本文です text=合成の値
paste_posted at_ms=2100 key_code=9 modifier_wait_ms=0
paste_receipt at_ms=2150
auto_enter result=sent
metrics_appended {"axis_a_ms":150,"error":null,"first_token_ms":80,"pause_commit_count":1,"target_app":"com.example.editor"}
history_appended inserted=true error=-
clipboard_restore done delay_ms=500
index_rebuilt scope=tracked count=2 ms=5 files=11 root=-
hotkey toggle_pressed at_ms=5000
target_app fixed=com.example.editor
hotkey toggle_pressed at_ms=6000
injection_rejected reason=input_target_changed_focus frontmost=com.example.editor original_role=AXTextArea
metrics_appended {"axis_a_ms":null,"error":"input_target_changed_focus","first_token_ms":90,"pause_commit_count":0,"target_app":"com.example.editor"}
history_appended inserted=false error=input_target_changed_focus
hotkey toggle_pressed at_ms=8000
escape
discarded
hotkey toggle_pressed at_ms=9000
start_error Error Domain=Example Code=1 file:///Users/example/Library/x.bin
segment_finalize_timeout reason=pause through_s=1.5
metrics_appended {"axis_a_ms":null,"error":"start_failed","first_token_ms":null,"pause_commit_count":0,"target_app":null}
LOG
cat >"$data/metrics.jsonl" <<'JSONL'
{"axis_a_ms":100,"error":null,"first_token_ms":50,"pause_commit_count":0,"target_app":"com.example.editor"}
{"axis_a_ms":600,"error":null,"first_token_ms":70,"pause_commit_count":2,"target_app":"com.example.terminal"}
not json
{"axis_a_ms":200,"error":"paste_receipt_timeout","first_token_ms":null,"pause_commit_count":1,"target_app":"com.example.editor"}
JSONL

# last: 既定は直近 1 回。
out="$(python3 "$script" last --dir "$data")"
contains "$out" 'toggle_pressed at_ms=9000' 'last shows the latest block'
lacks "$out" 'at_ms=8000' 'last 1 shows one block'
lacks "$out" '/Users/example' 'last redacts paths in error lines'
pass

# last N: 録音ごとに切り出し、確定の再押下では切らない。録音の外の行は出さない。
out="$(python3 "$script" last 4 --dir "$data")"
contains "$out" 'at_ms=2000' 'the confirming toggle stays in the block'
contains "$out" 'clipboard_restore done' 'a block ends at clipboard_restore'
contains "$out" 'discarded' 'a discarded recording is a block'
lacks "$out" 'index_rebuilt' 'lines outside recordings are dropped'
lacks "$out" 'permissions' 'lines before the first recording are dropped'
headings=0
while IFS= read -r line; do
  [[ "$line" != '## '* ]] || headings=$((headings + 1))
done <<<"$out"
[[ "$headings" == 4 ]] || fail "last 4 prints four headings, got $headings"
pass

# result index= は 1 行にまとめる。
contains "$out" 'results: 3 lines, first at_ms=1200, finals=1' 'results are summarised'
lacks "$out" 'result index=' 'raw result lines are hidden'
pass

# 本文・パス・機器名を伏せる。
contains "$out" 'path=<redacted>' 'path is redacted'
contains "$out" 'root=<redacted>' 'root is redacted'
contains "$out" 'final_text <redacted>' 'final text is redacted'
contains "$out" 'device="<redacted>"' 'device name is redacted'
for secret in '/tmp/example' 'x.png' '合成の本文' '合成の値' 'Example Mic'; do
  lacks "$out" "$secret" 'redaction'
done
pass

# errors: 計測の error と *_error / *_failed / *_timeout の行を回ごとに。
out="$(python3 "$script" errors 4 --dir "$data")"
contains "$out" 'error=input_target_changed_focus' 'errors lists metrics error'
contains "$out" 'error=start_failed' 'errors lists start_failed'
contains "$out" 'start_error' 'errors lists *_error lines'
contains "$out" 'segment_finalize_timeout' 'errors lists *_timeout lines'
lacks "$out" '/Users/example' 'errors redacts paths'
lacks "$out" 'at_ms=1000' 'errors skips recordings without errors'
pass

# summary: 中央値と最大。壊れた行は数えない。
out="$(python3 "$script" summary --dir "$data")"
contains "$out" '| axis_a_ms | 3 | 200 | 600 |' 'summary axis_a'
contains "$out" '| first_token_ms | 2 | 60 | 70 |' 'summary first_token'
contains "$out" '| pause_commit_count | 3 | 1 | 2 |' 'summary pause_commit_count'
contains "$out" 'paste_receipt_timeout: 1' 'summary error counts'
contains "$out" 'com.example.editor: 2' 'summary target_app counts'
out="$(python3 "$script" summary 1 --dir "$data")"
contains "$out" '| axis_a_ms | 1 | 200 | 200 |' 'summary N takes the latest rows'
pass

if python3 "$script" last --dir "$temporary_root/missing" >/dev/null 2>&1; then
  fail 'missing log must fail'
fi
pass

printf 'voxlog-script-tests: %d passed\n' "$pass_count"

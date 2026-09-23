#!/usr/bin/env python3
"""vox の診断ログ（logs/vox.log）と計測（metrics.jsonl）から直近の録音を、本文とパスを伏せて読む。"""

import argparse
import collections
import json
import os
import re
import statistics
import sys

DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/vox")
REDACTED = "<redacted>"
# 値が行末まで続く私的な項目（パスと --log-text の本文）。"-" と真偽値は伏せる必要がない。
PRIVATE_FIELD = re.compile(r"\b(path|root|inserted|text)=(?!(?:-|true|false)(?:\s|$)).*$")
DEVICE_NAME = re.compile(r'device="[^"]*"')
ABSOLUTE_PATH = re.compile(r"(?:file://)?(?<![\w.])/(?:[^\s/\"']+/)+[^\s\"']*")
ERROR_LINE = re.compile(r"^\w+_(?:error|failed|timeout)\b")


def fail(message):
    print("voxlog: " + message, file=sys.stderr)
    sys.exit(1)


def read_text(path, hint):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()
    except FileNotFoundError:
        fail("{} がありません。{}".format(path, hint))


def redact(line):
    if line.startswith("final_text ") and line != "final_text empty":
        return "final_text " + REDACTED
    line = PRIVATE_FIELD.sub(lambda match: match.group(1) + "=" + REDACTED, line)
    line = DEVICE_NAME.sub('device="{}"'.format(REDACTED), line)
    return ABSOLUTE_PATH.sub(REDACTED, line)


def recordings(lines):
    """録音ごとの行。開始の toggle_pressed から始め、確定の再押下では切らない。
    計測 1 行（または破棄）で締まった後の clipboard_restore で閉じ、次の開始で切る。"""
    blocks, current, finished = [], None, False
    for line in lines:
        if line.startswith("hotkey toggle_pressed") and (current is None or finished):
            current, finished = [line], False
            blocks.append(current)
            continue
        if current is None:
            continue
        current.append(line)
        if line.startswith(("metrics_appended ", "discarded")):
            finished = True
        elif line.startswith("clipboard_restore") and finished:
            current = None
    return blocks


def metrics_error(line):
    if not line.startswith("metrics_appended "):
        return None
    try:
        return json.loads(line[len("metrics_appended "):]).get("error")
    except (ValueError, AttributeError):
        return None


def summarise_results(block):
    results = [line for line in block if line.startswith("result index=")]
    if not results:
        return block
    first = re.search(r"at_ms=(\S+)", results[0])
    finals = sum("is_final=true" in line for line in results)
    summary = "results: {} lines, first at_ms={}, finals={}".format(
        len(results), first.group(1) if first else "?", finals)
    output, emitted = [], False
    for line in block:
        if not line.startswith("result index="):
            output.append(line)
        elif not emitted:
            output.append(summary)
            emitted = True
    return output


def log_blocks(arguments):
    lines = read_text(os.path.join(arguments.dir, "logs", "vox.log"),
                      "メニューバーの「診断ログを開く…」で場所を確かめてください")
    blocks = recordings(lines)[-arguments.count:]
    if not blocks:
        fail("録音の行（hotkey toggle_pressed）がありません。再現してから読み直してください")
    return blocks


def cmd_last(arguments):
    blocks = log_blocks(arguments)
    for index, block in enumerate(blocks, start=1):
        print("## 録音 {}/{}".format(index, len(blocks)))
        for line in summarise_results(block):
            print(redact(line))
        print()


def cmd_errors(arguments):
    blocks = log_blocks(arguments)
    found = False
    for index, block in enumerate(blocks, start=1):
        names = [name for name in map(metrics_error, block) if name]
        lines = [redact(line) for line in block if ERROR_LINE.match(line)]
        if not names and not lines:
            continue
        found = True
        print("## 録音 {}/{}".format(index, len(blocks)))
        for name in names:
            print("error=" + name)
        for line in lines:
            print(line)
        print()
    if not found:
        print("直近 {} 回にエラーはありません".format(len(blocks)))


def number(value):
    return str(int(value)) if float(value).is_integer() else "{:.1f}".format(value)


def cmd_summary(arguments):
    rows = []
    for line in read_text(os.path.join(arguments.dir, "metrics.jsonl"),
                          "swift run で起動した回は benchmarks/m1/metrics.jsonl にあります"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    rows = rows[-arguments.count:]
    print("対象: 直近 {} 回".format(len(rows)))
    print()
    # axis_a_ms は toggle_off → paste_received の差（MetricsSession.record）。
    print("| 指標 | 件数 | 中央値 | 最大 |")
    print("|---|---|---|---|")
    for key in ("axis_a_ms", "first_token_ms", "pause_commit_count"):
        values = [row[key] for row in rows if isinstance(row.get(key), (int, float))]
        if values:
            print("| {} | {} | {} | {} |".format(
                key, len(values), number(statistics.median(values)), number(max(values))))
        else:
            print("| {} | 0 | - | - |".format(key))
    for key in ("error", "target_app"):
        counts = collections.Counter(row.get(key) for row in rows if row.get(key))
        listed = ", ".join("{}: {}".format(name, count) for name, count in counts.most_common())
        print()
        print("{}: {}".format(key, listed or "なし"))


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dir", default=DEFAULT_DIR, help="保存先（検査用に差し替える）")
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, handler, default, text in (
            ("last", cmd_last, 1, "直近 N 回の録音の行"),
            ("errors", cmd_errors, 5, "直近 N 回の error と *_error / *_failed / *_timeout の行"),
            ("summary", cmd_summary, 20, "直近 N 回の計測の中央値と最大")):
        command = commands.add_parser(name, parents=[common], help=text)
        command.add_argument("count", nargs="?", type=int, default=default, metavar="N")
        command.set_defaults(handler=handler)
    arguments = parser.parse_args()
    if arguments.count < 1:
        parser.error("N は 1 以上")
    arguments.handler(arguments)


if __name__ == "__main__":
    main()

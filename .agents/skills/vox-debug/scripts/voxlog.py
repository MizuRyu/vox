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
# why: 機器名は引用符を含みうるので、次の項目（selection=）までを伏せる。
DEVICE_NAME = re.compile(r'device=".*"(?= selection=)|device="[^"]*"')
# why: パスは空白を含みうるので、見つけたら行末まで伏せる。
ABSOLUTE_PATH = re.compile(r"(?:file://)?(?<![\w.])/(?:[^\s/\"']+/)+.*$")
# 他アプリの bundle identifier。種類は利用者に聞き、出力では app-1 のような呼び名に置き換える。
APP_FIELD = re.compile(r'(\bfixed=|\bfrontmost=|\btarget=|"target_app":")([^\s",]+)')
EVENT_LINE = re.compile(r"^[a-z][a-z_]*(?: |$)")
ERROR_LINE = re.compile(r"^\w+_(?:error|failed|timeout)\b")
NOT_APP = ("-", "unknown", "null")


def fail(message):
    print("voxlog: " + message, file=sys.stderr)
    sys.exit(1)


def read_lines(directory, name, hint):
    """ログの区切りは LF だけ（本体は本文の LF だけを \\n にする）。CR や U+2028 で行を割らない。"""
    try:
        with open(os.path.join(directory, name), encoding="utf-8", errors="replace", newline="") as handle:
            return handle.read().split("\n")
    except FileNotFoundError:
        fail("{} がありません。{}".format(name, hint))
    except OSError as error:
        fail("{} を読めません（{}）".format(name, error.strerror))


class Redactor:
    """本文・パス・機器名を伏せ、bundle identifier を出現順の呼び名にする（1 回の実行の中で同じ名前）。"""

    def __init__(self):
        self.apps = {}

    def app(self, identifier):
        if identifier in NOT_APP:
            return identifier
        return self.apps.setdefault(identifier, "app-{}".format(len(self.apps) + 1))

    def line(self, line):
        if not line:
            return line
        if not EVENT_LINE.match(line):
            return REDACTED + "（形式の違う行）"
        if line.startswith("final_text ") and line != "final_text empty":
            return "final_text " + REDACTED
        line = PRIVATE_FIELD.sub(lambda match: match.group(1) + "=" + REDACTED, line)
        line = DEVICE_NAME.sub('device="{}"'.format(REDACTED), line)
        line = ABSOLUTE_PATH.sub(REDACTED, line)
        return APP_FIELD.sub(lambda match: match.group(1) + self.app(match.group(2)), line)


def recordings(lines):
    """録音ごとの行。開始は本体が必ず書く `target_app fixed=` と、その直前の toggle_pressed。
    確定の再押下では切らず、計測 1 行（または破棄）で締まった後の clipboard_restore で閉じる。"""
    blocks, current, finished, previous = [], None, False, None
    for line in lines:
        if not line:
            continue
        if line.startswith("target_app fixed="):
            start = [line]
            if current and current[-1].startswith("hotkey toggle_pressed"):
                start.insert(0, current.pop())
            elif current is None and previous and previous.startswith("hotkey toggle_pressed"):
                start.insert(0, previous)
            current, finished = start, False
            blocks.append(current)
        elif current is not None:
            current.append(line)
            if line.startswith(("metrics_appended ", "discarded")):
                finished = True
            elif line.startswith("clipboard_restore") and finished:
                current = None
        previous = line
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
    lines = read_lines(arguments.dir, "logs/vox.log", "メニューバーの「診断ログを開く…」で場所を確かめてください")
    blocks = recordings(lines)[-arguments.count:]
    if not blocks:
        fail("録音の行（target_app fixed=）がありません。再現してから読み直してください")
    return blocks


def cmd_last(arguments):
    blocks, redactor = log_blocks(arguments), Redactor()
    for index, block in enumerate(blocks, start=1):
        print("## 録音 {}/{}".format(index, len(blocks)))
        for line in summarise_results([redactor.line(line) for line in block]):
            print(line)
        print()


def cmd_errors(arguments):
    blocks, redactor = log_blocks(arguments), Redactor()
    found = False
    for index, block in enumerate(blocks, start=1):
        names = [error_name(name) for name in map(metrics_error, block) if name]
        lines = [redactor.line(line) for line in block if ERROR_LINE.match(line)]
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


def error_name(value):
    """error は列挙値（docs/development.md の表）。それ以外の形なら中身を出さない。"""
    return value if isinstance(value, str) and re.fullmatch(r"[a-z_]+", value) else REDACTED


def number(value):
    return str(int(value)) if float(value).is_integer() else "{:.1f}".format(value)


def cmd_summary(arguments):
    rows = []
    for line in read_lines(arguments.dir, "metrics.jsonl",
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
    redactor = Redactor()
    for key, name in (("error", error_name), ("target_app", redactor.app)):
        counts = collections.Counter(name(row[key]) for row in rows if isinstance(row.get(key), str))
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

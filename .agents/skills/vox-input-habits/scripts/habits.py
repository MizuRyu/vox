#!/usr/bin/env python3
"""エージェントへの入力履歴から、口癖・ぼかし言葉・依頼の形を数える（語と件数だけを出す）。

材料は Claude Code の ~/.claude/history.jsonl（display, timestamp ミリ秒）と
Codex の ~/.codex/history.jsonl（text, ts 秒）。vox-add-dictionary の sessions もこの読み込みと
「音声入力らしい」の判定を使う（定義はここ 1 か所）。
"""

import argparse
import collections
import datetime
import json
import os
import random
import re
import sys

CLAUDE_HISTORY = os.path.expanduser("~/.claude/history.jsonl")
CODEX_HISTORY = os.path.expanduser("~/.codex/history.jsonl")

JAPANESE = re.compile(r"[ぁ-んァ-ン一-龥]")
PASTED = re.compile(r"\[Pasted text[^\]]*\]")
# 言いよどみ。音声入力らしさの判定にも月別の集計にもこの 1 つだけを使う。
FILLERS = re.compile(
    r"(えっと|えーっと|えー|あの(?=[ー、 ])|なんか|まあ|うーん|うん(?=[、。 ])|ちょっと|っていうか|なんだろう)")
SECRET = re.compile(
    r"(sk-[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abp]-[A-Za-z0-9-]+|AKIA[0-9A-Z]{16}"
    r"|[A-Za-z0-9+/]{40,}|[\w.+-]+@[\w-]+\.[\w.-]+|(?:~|/Users/[^/\s]+)/\S*)")

# 語尾・ぼかし言葉。誤検出しやすい形（なんかな、静かな、何もかも、でしょうか）を除く。
# 件数をそのまま信じず、samples で抜粋を読んで当たり方を確かめる（SKILL.md の手順）。
ENDINGS = collections.OrderedDict([
    ("かな", r"(?<!なん)(?<![確静豊細僅愚鮮遥穏滑密厳微朗和速淡暖爽艶])かな(?!り|ら|い|しい|わ|う|え|く)"),
    ("かも", r"(?<![何誰]も)かも(?!め)"),
    ("よね", r"よね"),
    ("っけ", r"っけ"),
    ("多分", r"(たぶん|多分|恐らく|おそらく)"),
    ("気がする", r"気がする"),
    ("じゃない", r"じゃない(?!で|と|けど|から|し|のに|ように)"),
    ("じゃん", r"じゃん(?!け|ぷ|ぼ)"),
    ("でしょ（確認）", r"でしょ(?!う(か|ね))"),
    ("でしょうか（丁寧な依頼・質問）", r"でしょうか"),
    ("どう思う", r"どう思う"),
])
REQUESTS = collections.OrderedDict([
    ("〜してもらっていいですか", r"(てもらって(も)?いい(ですか|っすか)?|ていただいても|もらえますか)"),
    ("全部 / 一気に / いい感じに", r"(全部|一気に|いい感じに|よしなに|適当に)"),
    ("〜できる？ / できないかな", r"(できないですかね|できないかな|できますか|できる[？?])"),
    ("自己訂正（いや / じゃなくて）", r"(じゃなくて|いや[、 ]|違う違う|間違えた)"),
    ("〜いいんじゃね / のでは", r"(た方がいいんじゃ|ほうがいいんじゃ|べきじゃない|んじゃね)"),
    ("どうだろう / どうかな", r"(どうだろう|どうかな|どうなん)"),
])
TERMS = collections.OrderedDict(list(ENDINGS.items()) + list(REQUESTS.items()))


class Message(object):
    __slots__ = ("source", "timestamp", "text")

    def __init__(self, source, timestamp, text):
        self.source, self.timestamp, self.text = source, timestamp, text


def fail(message):
    print("habits: " + message, file=sys.stderr)
    sys.exit(1)


def _read(path, source, text_key, time_key, scale):
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return []
    except OSError as error:
        fail("{} の履歴を読めません（{}）".format(source, error.strerror))
    messages = []
    with handle:
        for line in handle:
            try:
                record = json.loads(line)
                text = record.get(text_key)
                timestamp = float(record.get(time_key) or 0) / scale
            except (ValueError, AttributeError, TypeError):
                continue
            if isinstance(text, str):
                messages.append(Message(source, timestamp, text.strip()))
    return messages


def keep(text):
    """本人が書いた日本語の発話だけを残す。コマンド、6 字未満、貼り付けの印は外す。"""
    if len(text) < 6 or text.startswith(("/", "!")) or PASTED.fullmatch(text):
        return False
    return bool(JAPANESE.search(text))


def load_messages(claude=CLAUDE_HISTORY, codex=CODEX_HISTORY):
    messages = (_read(claude, "claude", "display", "timestamp", 1000.0)
                + _read(codex, "codex", "text", "ts", 1.0))
    return [message for message in messages if keep(message.text)]


def is_voice_like(text):
    """音声入力らしい: 言いよどみが 2 回以上、または 80 字を超えて 1 回以上。打鍵でも書くので推定。"""
    fillers = len(FILLERS.findall(text))
    return fillers >= 2 or (len(text) > 80 and fillers >= 1)


def redact(text):
    return SECRET.sub("[伏字]", text)


def per_thousand(count, characters):
    return round(count * 1000.0 / characters, 2) if characters else 0.0


def analyze(messages):
    voice = [message for message in messages if is_voice_like(message.text)]
    other = [message for message in messages if not is_voice_like(message.text)]
    voice_chars = sum(len(message.text) for message in voice)
    other_chars = sum(len(message.text) for message in other)

    months = collections.OrderedDict()
    for message in sorted(messages, key=lambda item: item.timestamp):
        if message.timestamp <= 0:
            continue
        month = datetime.datetime.fromtimestamp(message.timestamp).strftime("%Y-%m")
        total, voiced = months.get(month, (0, 0))
        months[month] = (total + 1, voiced + (1 if is_voice_like(message.text) else 0))

    endings = collections.OrderedDict()
    for name, pattern in ENDINGS.items():
        expression = re.compile(pattern)
        final = re.compile(pattern + r"[\s？?。！!〜ー…]*$")
        endings[name] = {
            "total": sum(len(expression.findall(message.text)) for message in messages),
            "message_final": sum(1 for message in messages if final.search(message.text)),
            "voice_per_1000": per_thousand(
                sum(len(expression.findall(message.text)) for message in voice), voice_chars),
            "other_per_1000": per_thousand(
                sum(len(expression.findall(message.text)) for message in other), other_chars),
        }
    requests = collections.OrderedDict(
        (name, sum(1 for message in messages if re.search(pattern, message.text)))
        for name, pattern in REQUESTS.items())

    return {
        "japanese": len(messages),
        "voice_like": len(voice),
        "by_source": dict(collections.Counter(message.source for message in messages)),
        "by_month": [{"month": month, "messages": total, "voice_like": voiced}
                     for month, (total, voiced) in months.items()],
        "endings": endings,
        "requests": requests,
        "average_length": {
            "voice_like": round(voice_chars / len(voice)) if voice else 0,
            "other": round(other_chars / len(other)) if other else 0,
        },
    }


def print_report(result):
    print("## 材料")
    print()
    print("| 項目 | 件数 |")
    print("|---|---|")
    print("| 日本語の発話 | {} |".format(result["japanese"]))
    print("| 音声入力らしい | {} |".format(result["voice_like"]))
    for source, count in sorted(result["by_source"].items()):
        print("| うち {} | {} |".format(source, count))
    print()
    print("## 音声入力らしい割合（月別）")
    print()
    print("| 月 | 発話 | 音声入力らしい | 割合 |")
    print("|---|---|---|---|")
    for row in result["by_month"]:
        print("| {} | {} | {} | {}% |".format(
            row["month"], row["messages"], row["voice_like"],
            round(row["voice_like"] * 100.0 / row["messages"]) if row["messages"] else 0))
    print()
    print("## 語尾・ぼかし言葉")
    print()
    print("| 語 | 件数 | 文末 | 1000字あたり（音声） | 1000字あたり（それ以外） |")
    print("|---|---|---|---|---|")
    for name, row in result["endings"].items():
        print("| {} | {} | {} | {} | {} |".format(
            name, row["total"], row["message_final"], row["voice_per_1000"], row["other_per_1000"]))
    print()
    print("## 依頼の形（含む発話の数）")
    print()
    print("| 形 | 発話 |")
    print("|---|---|")
    for name, count in result["requests"].items():
        print("| {} | {} |".format(name, count))
    print()
    print("## 平均文字数")
    print()
    print("| 区分 | 発話 | 平均文字数 |")
    print("|---|---|---|")
    print("| 音声入力らしい | {} | {} |".format(result["voice_like"], result["average_length"]["voice_like"]))
    print("| それ以外 | {} | {} |".format(
        result["japanese"] - result["voice_like"], result["average_length"]["other"]))


def materials(arguments):
    messages = load_messages(arguments.claude, arguments.codex)
    if not messages:
        fail("入力履歴が見つかりません（Claude Code / Codex の history.jsonl）")
    return messages


def cmd_report(arguments):
    result = analyze(materials(arguments))
    if arguments.json:
        print(json.dumps(result, ensure_ascii=False, indent=1))
    else:
        print_report(result)


def cmd_samples(arguments):
    if arguments.term not in TERMS:
        fail("知らない語です。使える語: " + " / ".join(TERMS))
    expression = re.compile(TERMS[arguments.term])
    windows = []
    for message in materials(arguments):
        # why: 伏せてから窓を切る。先に切ると、鍵の途中から始まる窓で残りが見える。
        text = redact(message.text).replace("\n", " ")
        for match in expression.finditer(text):
            start, end = max(0, match.start() - 15), min(len(text), match.end() + 10)
            label = "音声" if is_voice_like(message.text) else "それ以外"
            windows.append("[{}] …{}…".format(label, text[start:end]))
    random.Random(arguments.seed).shuffle(windows)
    print("## {}（{} 件中 {} 件）".format(arguments.term, len(windows), min(arguments.n, len(windows))))
    for window in windows[:arguments.n]:
        print("- " + window)


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--claude", default=CLAUDE_HISTORY, help="Claude Code の history.jsonl")
    common.add_argument("--codex", default=CODEX_HISTORY, help="Codex の history.jsonl")
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    report = commands.add_parser("report", parents=[common], help="割合・件数・密度を表で出す")
    report.add_argument("--json", action="store_true")
    report.set_defaults(handler=cmd_report)

    samples = commands.add_parser("samples", parents=[common], help="語の当たり方を短い抜粋で確かめる")
    samples.add_argument("term")
    samples.add_argument("--n", type=int, default=12, choices=range(1, 31), metavar="1-30")
    samples.add_argument("--seed", type=int, default=7)
    samples.set_defaults(handler=cmd_samples)

    arguments = parser.parse_args()
    arguments.handler(arguments)


if __name__ == "__main__":
    main()

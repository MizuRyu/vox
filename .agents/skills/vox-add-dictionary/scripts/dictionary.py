#!/usr/bin/env python3
"""vox の辞書（dictionary.tsv、ADR-019）に入れる語を履歴から提案し、行を追記する。"""

import argparse
import collections
import json
import os
import re
import stat
import sys

DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/vox")
MAXIMUM_BYTES = 64 * 1024
# why: Sources/VoxApp/Settings/DictionaryStore.swift の template と同じ文面。変えるときは両方直す
# （Tests/Tooling/dictionary-script-tests.sh が一致を検査する）。
TEMPLATE = (
    "# vox の辞書。1 行に「置き換える表記」、タブ、「入れたい表記」を書きます。\n"
    "# # で始まる行と空行は無視します。右側を空にすると、その語を削除します。\n"
    "# 表計算アプリで開くと形式が変わることがあるので、テキストエディタで編集してください。\n"
    "# 例（行頭の # を外して使います）\n"
    "#松尾\t末尾\n"
    "#なんか、\t\n"
)

KATAKANA = re.compile(r"[ァ-ヶー]{2,}")
TYPED_WORD = re.compile(r"[a-z][a-z0-9+.-]{1,}", re.IGNORECASE)

KANA = dict(zip(
    "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"
    "ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポヴァィゥェォャュョヮヵヶ",
    "a i u e o ka ki ku ke ko sa shi su se so ta chi tsu te to na ni nu ne no "
    "ha hi fu he ho ma mi mu me mo ya yu yo ra ri ru re ro wa o n "
    "ga gi gu ge go za ji zu ze zo da ji zu de do ba bi bu be bo pa pi pu pe po vu "
    "a i u e o ya yu yo wa ka ke".split()))


def fail(message):
    print("dictionary: " + message, file=sys.stderr)
    sys.exit(1)


# --- 辞書ファイル -----------------------------------------------------------

def open_private(path, flags):
    """リンクを辿らず、本人の通常ファイル（リンク数 1）だけを開く。アプリの読み込みと同じ条件。"""
    try:
        descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except FileNotFoundError:
        return None
    except OSError as error:
        fail("{} を開けません（{}）".format(os.path.basename(path), error.strerror))
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
        os.close(descriptor)
        fail("{} が通常のファイルではありません".format(os.path.basename(path)))
    return descriptor


def read_dictionary(path):
    descriptor = open_private(path, os.O_RDONLY)
    if descriptor is None:
        return None
    with os.fdopen(descriptor, "rb") as handle:
        data = handle.read(MAXIMUM_BYTES + 1)
    if len(data) > MAXIMUM_BYTES:
        fail("dictionary.tsv が 64KiB を超えています")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        fail("dictionary.tsv が UTF-8 ではありません")


def parse_dictionary(text):
    """(左辺 → 行番号, [(左, 右)], 壊れた行番号)。規則は DictionaryTable（VoxCore）と同じ。"""
    seen, entries, broken = {}, [], []
    for number, line in enumerate(text.splitlines(), start=1):
        if line.startswith("#") or not line.strip():
            continue
        columns = line.split("\t")
        if len(columns) != 2 or not columns[0] or columns[0] in seen:
            broken.append(number)
            continue
        seen[columns[0]] = number
        entries.append((columns[0], columns[1]))
    return seen, entries, broken


def dictionary_path(directory):
    return os.path.join(directory, "dictionary.tsv")


# --- suggest ---------------------------------------------------------------

def romaji(word):
    """素朴なヘボン式。長音は落とし、促音は次の子音を重ねる。"""
    output, double = "", False
    for kana in word:
        if kana == "ー":
            continue
        if kana == "ッ":
            double = True
            continue
        syllable = KANA.get(kana, "")
        if kana in "ャュョ" and output.endswith("i"):
            stem = output[:-1]
            output = stem + syllable[1:] if stem.endswith(("sh", "ch", "j")) else stem + syllable
            continue
        if kana in "ァィゥェォ" and output[-1:] in ("a", "i", "u", "e", "o"):
            output = (output[:-1] or "w") + syllable  # ティ → ti、ウィ → wi
            continue
        if double and syllable[:1] not in "aiueon":
            syllable = syllable[0] + syllable
        double = False
        output += syllable
    return output


def skeleton(word):
    """英字の綴りとローマ字を同じ土俵に置く子音の並び（claude と kurodo が同じ krd になる）。"""
    text = word.lower().replace("ph", "f").replace("x", "ks")
    text = re.sub(r"g(?=[eiy])", "j", text)
    text = text.translate(str.maketrans("cqlv", "kkrb"))
    text = re.sub(r"[aeiouyhw.+-]", "", text)
    return re.sub(r"(.)\1+", r"\1", text)


def edit_distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, start=1):
        current = [i]
        for j, b in enumerate(right, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1]


def resembles(kana, word):
    reading = romaji(kana)
    key, other = skeleton(reading), skeleton(word)
    if len(key) >= 2 and key == other:
        return True
    # why: 英語の黙字（terminal の r）は長い語で 1 文字だけ許す。
    if min(len(key), len(other)) >= 4 and edit_distance(key, other) <= 1:
        return True
    shorter = min(len(reading), len(word))
    if shorter < 4:
        return False
    return reading.startswith(word) or word.startswith(reading) or edit_distance(reading, word) <= 2


def count_katakana(history_path):
    counts = collections.Counter()
    try:
        handle = open(history_path, encoding="utf-8", errors="replace")
    except FileNotFoundError:
        fail("history.jsonl がありません。録音して確定すると溜まります")
    with handle:
        for line in handle:
            try:
                text = json.loads(line).get("raw_text")
            except (ValueError, AttributeError):
                continue
            if isinstance(text, str):
                for word in KATAKANA.findall(text):
                    word = word.lstrip("ー")
                    if len(word) >= 2:
                        counts[word] += 1
    return counts


def count_typed(paths):
    counts = collections.Counter()
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for word in TYPED_WORD.findall(handle.read()):
                word = word.lower().rstrip(".-")
                if len(word) >= 2:
                    counts[word] += 1
    return counts


def group_long_vowels(counts):
    """長音の有無だけ違う表記を 1 候補にまとめる。"""
    groups = collections.defaultdict(collections.Counter)
    for word, count in counts.items():
        groups[word.replace("ー", "")][word] = count
    return list(groups.values())


def registered_mark(variants, registered):
    hits = [word for word in variants if word in registered]
    if not hits:
        return ""
    if len(hits) == len(variants):
        return "済"
    return "一部（{}）".format(" / ".join(hits))


def cmd_suggest(arguments):
    counts = count_katakana(os.path.join(arguments.dir, "history.jsonl"))
    typed = count_typed(arguments.typed)
    text = read_dictionary(dictionary_path(arguments.dir))
    registered = parse_dictionary(text)[0] if text else {}

    rows, matched = [], set()
    for group in group_long_vowels(counts):
        total = sum(group.values())
        if total < arguments.min_count:
            continue
        variants = [word for word, _ in sorted(group.items(), key=lambda item: (-item[1], item[0]))]
        candidates = sorted(
            (word for word in typed if resembles(variants[0], word)),
            key=lambda word: (-typed[word], word))[:3]
        matched.update(candidates)
        rows.append((total, " / ".join(variants), candidates, registered_mark(variants, registered)))

    print("## 履歴に出たカタカナ語")
    print()
    print("| 認識される表記 | 件数 | 英字の候補 | 打鍵回数 | 登録済み |")
    print("|---|---|---|---|---|")
    for total, display, candidates, mark in sorted(rows, key=lambda row: (-row[0], row[1])):
        print("| {} | {} | {} | {} | {} |".format(
            display, total, ", ".join(candidates),
            ", ".join(str(typed[word]) for word in candidates), mark))

    if arguments.typed:
        unmatched = sorted(
            (word for word, count in typed.items() if count >= arguments.min_count and word not in matched),
            key=lambda word: (-typed[word], word))[:30]
        print()
        print("## 打鍵だけに出た英字の語（履歴に対応するカタカナが無い。上位 30）")
        print()
        print("| 英字の語 | 打鍵回数 |")
        print("|---|---|")
        for word in unmatched:
            print("| {} | {} |".format(word, typed[word]))


# --- add / list ------------------------------------------------------------

def parse_row(row):
    if "\n" in row or "\r" in row:
        fail("1 つの引数に改行があります。1 行ずつ別の引数で渡してください")
    columns = row.split("\t")
    if len(columns) != 2:
        fail("「{}」のタブが 1 つではありません（例: $'クロード\\tclaude'）".format(row))
    left, right = columns
    if not left.strip():
        fail("置き換える表記（タブの左）が空です: {!r}".format(row))
    if left.startswith("#"):
        fail("# で始まる左辺はコメントとして無視されます: {}".format(left))
    return left, right


def ensure_directory(directory):
    if os.path.islink(directory):
        fail("保存先がシンボリックリンクです")
    if not os.path.isdir(directory):
        os.makedirs(directory, mode=0o700)
        os.chmod(directory, 0o700)


def cmd_add(arguments):
    rows = [parse_row(row) for row in arguments.rows]
    lefts = [left for left, _ in rows]
    for left in lefts:
        if lefts.count(left) > 1:
            fail("「{}」を 2 回渡しています".format(left))

    path = dictionary_path(arguments.dir)
    existing = read_dictionary(path)
    base = TEMPLATE if existing is None else existing
    seen = parse_dictionary(base)[0]
    for left in lefts:
        if left in seen:
            fail("「{}」はすでに {} 行目にあります".format(left, seen[left]))

    separator = "\n" if base and not base.endswith(("\n", "\r")) else ""
    payload = separator + "".join("{}\t{}\n".format(left, right) for left, right in rows)
    if existing is None:
        payload = TEMPLATE + payload
    current = len(existing.encode("utf-8")) if existing is not None else 0
    if current + len(payload.encode("utf-8")) > MAXIMUM_BYTES:
        fail("追加すると 64KiB を超えます")

    ensure_directory(arguments.dir)
    descriptor = open_private(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
    try:
        os.fchmod(descriptor, 0o600)
        data = payload.encode("utf-8")
        while data:
            data = data[os.write(descriptor, data):]
    finally:
        os.close(descriptor)
    for left, right in rows:
        print("追加しました: {} → {}".format(left, right or "（削除）"))
    print("次の録音から効きます。")


def cmd_list(arguments):
    text = read_dictionary(dictionary_path(arguments.dir))
    if text is None:
        print("辞書はまだありません（dictionary.tsv が無い）")
        return
    _, entries, broken = parse_dictionary(text)
    for left, right in entries:
        print("{} → {}".format(left, right or "（削除）"))
    print("{} 件".format(len(entries)))
    if broken:
        print("読み込まれない行: {}".format(", ".join("{} 行目".format(n) for n in broken)))


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dir", default=DEFAULT_DIR, help="保存先（検査用に差し替える）")
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    suggest = commands.add_parser("suggest", parents=[common], help="履歴のカタカナ語を数えて提案する")
    suggest.add_argument("--typed", action="append", default=[], metavar="FILE",
                         help="普段キーボードで打つ文章（英字の語を数えて対応づける）")
    suggest.add_argument("--min-count", type=int, default=2)
    suggest.set_defaults(handler=cmd_suggest)

    add = commands.add_parser("add", parents=[common], help="'左辺<TAB>右辺' を末尾に足す")
    add.add_argument("rows", nargs="+")
    add.set_defaults(handler=cmd_add)

    listing = commands.add_parser("list", parents=[common], help="登録済みの行を表示する")
    listing.set_defaults(handler=cmd_list)

    arguments = parser.parse_args()
    arguments.handler(arguments)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""vox の辞書（dictionary.tsv、ADR-019）に入れる語を履歴から提案し、行を追記する。"""

import argparse
import collections
import json
import os
import re
import stat
import subprocess
import sys
import unicodedata

DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/vox")
MAXIMUM_BYTES = 64 * 1024
# why: `DictionaryStore.swift` の template と同文。変えるときは両方（dictionary-script-tests.sh が一致を検査する）。
TEMPLATE = (
    "# vox の辞書。1 行に「認識される表記」、タブ、「入れたい表記」を書きます。\n"
    "# # で始まる行と空行は無視します。右側を空にすると、その語を削除します。\n"
    "# 表計算アプリで開くと形式が変わることがあるので、テキストエディタで編集してください。\n"
    "# 例（行頭の # を外して使います）\n"
    "#松尾\t末尾\n"
    "#なんか、\t\n"
)

KATAKANA = re.compile(r"[ァ-ヶー]{2,}")
# why: 本体は Character.isNewline で行を割るので、U+2028 なども改行として拒否する（str.splitlines と同じ集合）。
LINE_BREAKS = "\n\r\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029"
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
        # why: O_NONBLOCK は FIFO を開いたまま待たないため（本体の PrivateFileIO と同じ）。
        descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
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
        if len(columns) != 2 or not columns[0] or same_key(columns[0]) in seen:
            broken.append(number)
            continue
        seen[same_key(columns[0])] = number
        entries.append((columns[0], columns[1]))
    return seen, entries, broken


def same_key(left):
    """Swift の String は正準等価で比べる（「ガ」と「カ + 濁点」は同じ左辺）。重複の判定だけに使う。"""
    return unicodedata.normalize("NFC", left)


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
    text = re.sub(r"c(?=[eiy])", "s", text)
    text = text.translate(str.maketrans("cqlv", "kkrb"))
    text = re.sub(r"[aeiouyhw.+-]", "", text)
    return re.sub(r"(.)\1+", r"\1", text)


def sounds(word):
    """綴りと読みを、母音を残したまま同じ土俵に置く（zoltech と zorutekku が同じ zortek になる）。
    子音は skeleton と同じに寄せ、日本語の読みが子音の後に足す u（t / d の後は o）を落とす。"""
    text = word.lower().replace("ph", "f").replace("x", "ks")
    text = re.sub(r"g(?=[eiy])", "j", text)
    text = re.sub(r"c(?=[eiy])", "s", text)
    text = text.translate(str.maketrans("cqlv", "kkrb"))
    text = re.sub(r"[hwy.+-]", "", text)
    text = re.sub(r"(.)\1+", r"\1", text)
    text = re.sub(r"(?<=[bcdfgjklmnprstvz])u(?=[bcdfgjklmnprstvz0-9]|$)", "", text)
    return re.sub(r"(?<=[td])o(?=[bcdfgjklmnprstvz0-9]|$)", "", text)


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
    except OSError as error:
        fail("history.jsonl を読めません（{}）".format(error.strerror))
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
    for number, path in enumerate(paths, start=1):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as error:
            fail("{} 番目の --typed を読めません（{}）".format(number, error.strerror))
        for word in TYPED_WORD.findall(text):
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
    hits = [word for word in variants if same_key(word) in registered]
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


# --- sessions --------------------------------------------------------------
# エージェントへの入力履歴（vox が認識した後の文が混ざる）から、誤変換の対を推定する。
# 誤変換は 1〜3 回しか出ないので件数では見つからない。逆向きに、打鍵でよく打つ語（正しい表記）を起点にして、
# 音声らしい発話の中で読みの子音の並びが同じか 1 音違いの語（認識される表記）を探す。

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
READINGS = os.path.join(SCRIPTS, "readings.swift")
# 履歴の読み込みと「音声入力らしい」の判定は vox-input-habits が持つ（定義を 1 か所にする）。
HABITS = os.path.join(os.path.dirname(os.path.dirname(SCRIPTS)), "vox-input-habits", "scripts")
WORDY = re.compile(r"[ァ-ヶ一-龥A-Za-z0-9]")
STOPWORDS = frozenset(
    "the and for with this that from have not are you your can will was were but all any one out "
    "use get set new add run see how why what when where which who its into than then them they "
    "there here also just like more some such only very want need make made done dont does did "
    "has had our ours http https www com org".split())
MAXIMUM_SURFACE = 12
# 認識される表記に小文字の英単語は入れない。vox の認識は日本語を小文字の英単語に変えないので、
# それは英語で話した語（「users」）か、英単語にまたがった窓（「ハskill」）。英字は大文字と数字だけ（GPD、QN3.5）。
LOWERCASE_WORD = re.compile(r"[a-z]{2,}")
# 表記に使える文字。記号（「数:%d」「SERVICE_NAME」）を含む窓はコードの断片なので外す。
SURFACE = re.compile(r"[ァ-ヶー一-龥ぁ-んA-Z0-9 .]+")
KANJI = re.compile(r"[一-龥]")
# 普通の英単語（macOS 同梱の単語表）は、固有名（製品名・サービス名）より後に並べる。無ければ並びに使わない。
WORD_LIST = "/usr/share/dict/words"


def plain_english():
    try:
        with open(WORD_LIST, encoding="utf-8", errors="replace") as handle:
            return frozenset(line.strip() for line in handle if line.strip().islower())
    except OSError:
        return frozenset()


def is_plain_english(word, english):
    return any(stem in english for stem in (word, word[:-1] if word.endswith("s") else "",
                                            word[:-2] if word.endswith("es") else ""))


def read_aloud(texts):
    """文ごとに [(開始, 長さ, 読み)]（UTF-16 単位）。macOS の日本語の単語分割（readings.swift）を使う。"""
    lines = "".join(text.replace("\r", " ").replace("\n", " ") + "\n" for text in texts)
    try:
        output = subprocess.run(["swift", READINGS], input=lines, capture_output=True, text=True,
                                check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        fail("読みを取れません。Xcode の swift が要ります（xcode-select -p で確かめる）")
    sentences, current = [], []
    for line in output.split("\n"):
        if not line:
            sentences.append(current)
            current = []
            continue
        start, length, reading = line.split("\t", 2)
        current.append((int(start), int(length), reading))
    return sentences[:len(texts)]


def plain(reading):
    """ōpasu → opasu。英字と数字だけにする。"""
    decomposed = unicodedata.normalize("NFKD", reading.lower())
    return "".join(character for character in decomposed if character.isascii() and character.isalnum())


def deletions(key):
    return {key[:i] + key[i + 1:] for i in range(len(key))}


class Targets(object):
    """打鍵でよく打つ語。子音の並びと、そこから 1 音消した形で引けるようにする。"""

    def __init__(self, counts):
        self.counts, self.exact, self.near = counts, collections.defaultdict(set), collections.defaultdict(set)
        for word in counts:
            key = skeleton(word)
            if len(key) < 2:
                continue
            self.exact[key].add(word)
            if len(key) >= 3:
                for variant in {key} | deletions(key):
                    self.near[variant].add(word)

    def match(self, reading):
        """[(語, 一致か, 綴りとの距離)]。一致 = 子音の並びが同じ。近い = 1 音違い（並びが 3 音以上）。
        どちらも、読み全体が綴りと近いもの（語の長さの半分以内、最低 2 文字）だけを残す。
        子音だけでは、無関係な英単語との偶然の一致が多すぎるため。"""
        key = skeleton(reading)
        candidates = {word: True for word in self.exact.get(key, ())}
        variants = {key} | deletions(key) if len(key) >= 3 else {key}
        for variant in variants:
            for word in self.near.get(variant, ()):
                if word not in candidates and edit_distance(key, skeleton(word)) == 1:
                    candidates[word] = False
        found = []
        heard = sounds(reading)
        for word, exact in candidates.items():
            spelled = sounds(word)
            distance = edit_distance(heard, spelled)
            if distance <= max(2, len(spelled) // 2):
                found.append((word, exact, distance))
        return found


def windows(text, tokens):
    """連続する 1〜3 語の（表記, 読み）。ひらがなだけの語（助詞など）はまたがない。"""
    data = text.encode("utf-16-le")

    def cut(start, length):
        return data[start * 2:(start + length) * 2].decode("utf-16-le", errors="replace")

    for first in range(len(tokens)):
        reading = ""
        for last in range(first, min(first + 3, len(tokens))):
            start, length, token_reading = tokens[last]
            word = cut(start, length)
            if not WORDY.search(word):
                break
            # why: 英字と数字は綴りそのものが読み。分割器は「3.5」を「5」と読む。
            reading += plain(word if word.isascii() else token_reading)
            first_start = tokens[first][0]
            surface = cut(first_start, start + length - first_start).strip()
            if len(surface) <= MAXIMUM_SURFACE:
                yield first_start, start + length, surface, reading


def session_pairs(voice_texts, typed_text, targets):
    """Counter[(表記, 語)]、{(表記, 語): (一致か, 綴りとの距離)}、{表記: 打鍵の文に出た回数}。
    同じ発話で同じ語に当たる短い表記は、長い方に含める。"""
    counts, quality, in_typed = collections.Counter(), {}, {}
    for text, tokens in zip(voice_texts, read_aloud(voice_texts)):
        hits = []
        for start, end, surface, reading in windows(text, tokens):
            if len(skeleton(reading)) < 2 or LOWERCASE_WORD.search(surface) \
                    or not SURFACE.fullmatch(surface):
                continue
            for word, exact, distance in targets.match(reading):
                if surface.lower().replace(" ", "") == word:
                    continue
                # why: 漢字を含む表記は、音が同じで 4 音以上の語に限る。普段の語が短い英単語に偶然似るため。
                if KANJI.search(surface) and not (distance == 0 and len(sounds(word)) >= 4):
                    continue
                if surface not in in_typed:
                    in_typed[surface] = typed_text.count(surface.lower())
                # why: 正しい表記より打鍵の文でよく出る表記は、誤変換ではなく普段の語（「トレス表示」など）。
                if in_typed[surface] < targets.counts[word]:
                    hits.append((end - start, start, end, surface, word, (exact, distance)))
        accepted = []
        for _, start, end, surface, word, grade in sorted(hits, key=lambda hit: hit[:3], reverse=True):
            if any(word == other and start >= s and end <= e for s, e, other in accepted):
                continue
            accepted.append((start, end, word))
            counts[(surface, word)] += 1
            quality[(surface, word)] = grade
    return counts, quality, in_typed


def best_targets(counts, quality, typed):
    """表記ごとに、音が近い → よく打つ → 子音の並びが一致 の順で並べた語。"""
    by_surface = collections.defaultdict(list)
    for (surface, word), count in counts.items():
        exact, distance = quality[(surface, word)]
        by_surface[surface].append(((distance, -typed[word], not exact, word), word, count))
    return {surface: sorted(options) for surface, options in by_surface.items()}


def cmd_sessions(arguments):
    sys.path.insert(0, HABITS)
    import habits  # noqa: E402  # pylint: disable=import-outside-toplevel

    messages = habits.load_messages(arguments.claude, arguments.codex)
    if not messages:
        fail("入力履歴が見つかりません（Claude Code / Codex の history.jsonl）")
    voice = [message.text for message in messages if habits.is_voice_like(message.text)]
    typed_texts = [message.text for message in messages if not habits.is_voice_like(message.text)]
    typed_text = "\n".join(typed_texts).lower()
    typed = collections.Counter()
    for text in typed_texts:
        for word in TYPED_WORD.findall(text):
            word = word.lower().rstrip(".-")
            if len(word) >= 3 and word not in STOPWORDS:
                typed[word] += 1
    for word, count in count_typed(arguments.typed).items():
        if len(word) >= 3 and word not in STOPWORDS:
            typed[word] += count
    targets = Targets({word: count for word, count in typed.items() if count >= arguments.min_typed})

    counts, quality, in_typed = session_pairs(voice, typed_text, targets)
    text = read_dictionary(dictionary_path(arguments.dir))
    registered = parse_dictionary(text)[0] if text else {}

    # 1 表記 1 行。並びは、一致を先に、その中は「正しい表記の打鍵回数 ÷ 表記が打鍵の文に出た回数」が大きい順
    # （普段は打たない表記ほど誤変換らしい。ファイル → file のような普段の語は下に沈む）。
    options = best_targets(counts, quality, typed)
    english = plain_english()

    def order(item):
        surface, ranked = item
        (distance, _, not_exact, _), best, _ = ranked[0]
        # 音が同じ → 3 文字より長い → 固有名 → 子音の並びが一致 → 普段打たない表記ほど先。
        return (distance > 0, len(best) <= 3, is_plain_english(best, english), not_exact,
                -typed[best] / (1.0 + in_typed[surface]), surface)

    rows = sorted(options.items(), key=order)[:arguments.limit]
    print("## 誤変換の候補（音声らしい発話 {} 件 / 打鍵の語 {} 種）".format(len(voice), len(targets.counts)))
    print()
    print("| 認識される表記 | 入れたい表記の候補 | 音声での件数 | 打鍵回数 | 近さ | 登録済み |")
    print("|---|---|---|---|---|---|")
    for surface, ranked in rows:
        (_, _, not_exact, _), best, count = ranked[0]
        alternatives = [word for _, word, _ in ranked[1:3]]
        shown = best + ("（ほか: {}）".format(", ".join(alternatives)) if alternatives else "")
        print("| {} | {} | {} | {} | {} | {} |".format(
            surface, shown, count, typed[best], "近い" if not_exact else "一致",
            "済" if same_key(surface) in registered else ""))


# --- add / list ------------------------------------------------------------

def parse_row(row):
    if any(character in LINE_BREAKS for character in row):
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
    keys = [same_key(left) for left in lefts]
    for left, key in zip(lefts, keys):
        if keys.count(key) > 1:
            fail("「{}」を 2 回渡しています".format(left))

    path = dictionary_path(arguments.dir)
    existing = read_dictionary(path)
    base = TEMPLATE if existing is None else existing
    seen = parse_dictionary(base)[0]
    for left, key in zip(lefts, keys):
        if key in seen:
            fail("「{}」はすでに {} 行目にあります".format(left, seen[key]))

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

    sessions = commands.add_parser(
        "sessions", parents=[common], help="エージェントへの入力履歴から誤変換の対を推定する")
    sessions.add_argument("--claude", default=os.path.expanduser("~/.claude/history.jsonl"))
    sessions.add_argument("--codex", default=os.path.expanduser("~/.codex/history.jsonl"))
    sessions.add_argument("--typed", action="append", default=[], metavar="FILE",
                          help="打鍵の文章を足す（commit message など）")
    sessions.add_argument("--min-typed", type=int, default=3, help="正しい表記として扱う打鍵回数の下限")
    sessions.add_argument("--limit", type=int, default=300)
    sessions.set_defaults(handler=cmd_sessions)

    add = commands.add_parser("add", parents=[common], help="'左辺<TAB>右辺' を末尾に足す")
    add.add_argument("rows", nargs="+")
    add.set_defaults(handler=cmd_add)

    listing = commands.add_parser("list", parents=[common], help="登録済みの行を表示する")
    listing.set_defaults(handler=cmd_list)

    arguments = parser.parse_args()
    arguments.handler(arguments)


if __name__ == "__main__":
    main()

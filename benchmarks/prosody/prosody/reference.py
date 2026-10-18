"""「正しい文」の欄に最初から入れておく修正案。利用者の vox の辞書（dictionary.tsv）と同じ置き換えだけを入れる。

読点は入れない。Apple の語の区間は隙間なく続き、片は 1〜2 文字に割れるので、音量の沈黙から置くと
「一、旦」「パ、クって」のように語の途中に入った（2026-10-18 に 161 文で試した）。推測で語を直すこともしない。
文末の記号は画面が選んだ記号に合わせる。
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

DICTIONARY = Path.home() / "Library/Application Support/vox/dictionary.tsv"


@lru_cache(maxsize=1)
def _dictionary(modified: float) -> tuple[tuple[str, str], ...]:
    entries = []
    for line in DICTIONARY.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#") or "\t" not in line:
            continue
        source, target = line.split("\t", 1)
        if source:
            entries.append((source, target))
    return tuple(sorted(entries, key=lambda e: -len(e[0])))


def suggest(text: str) -> str | None:
    """vox の DictionaryPass と同じ、左からの最長一致。置き換えた結果は再び見ない。元と同じなら None。"""
    if not DICTIONARY.exists():
        return None
    entries = _dictionary(DICTIONARY.stat().st_mtime)
    out, i = [], 0
    while i < len(text):
        for source, target in entries:
            if text.startswith(source, i):
                out.append(target)
                i += len(source)
                break
        else:
            out.append(text[i])
            i += 1
    result = "".join(out)
    return result if result != text else None

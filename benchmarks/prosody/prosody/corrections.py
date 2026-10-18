"""vox が貼り付けた本文と、その後エージェントへ実際に送った文を突き合わせる。

vox の履歴（history.jsonl）には認識した本文しか残らない。貼り付けた後に手で直した結果は、
送り先が Claude Code / Codex なら、そのセッション記録に残る。両者の差分が、利用者の直しになる。

uv run python -m prosody.corrections
出力: <データの置き場>/corrections.jsonl（文の組。本人の発言なのでリポジトリには置かない）と、集計の表示。
"""

from __future__ import annotations

import json
import re
import unicodedata
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from difflib import SequenceMatcher
from pathlib import Path

from prosody import voxdata

HISTORY = Path.home() / "Library/Application Support/vox/history.jsonl"
CLAUDE = Path.home() / ".claude/projects"
CODEX = Path.home() / ".codex/sessions"
# 貼り付けから送信までの猶予。直しながら送るので、長めに取る。
WINDOW = timedelta(minutes=30)
MATCH_RATIO = 0.6
SMALL_EDIT_RATIO = 0.85


@dataclass(frozen=True)
class Message:
    at: datetime
    text: str
    source: str


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    return re.sub(r"\s+", " ", text).strip()


def _parse_time(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def history(since: datetime | None = None) -> list[dict]:
    rows = []
    for line in HISTORY.read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        at = _parse_time(row.get("at", ""))
        if at and row.get("inserted_text") and (since is None or at >= since):
            rows.append({**row, "at_dt": at})
    return rows


def _claude_texts(entry: dict) -> list[str]:
    if entry.get("type") != "user" or entry.get("isMeta") or entry.get("isSidechain"):
        return []
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
    return []


def _codex_texts(entry: dict) -> list[str]:
    payload = entry.get("payload") or {}
    if entry.get("type") != "response_item" or payload.get("role") != "user":
        return []
    return [c.get("text", "") for c in payload.get("content") or [] if c.get("type") == "input_text"]


def messages(since: datetime) -> list[Message]:
    """since 以降に更新されたセッション記録から、利用者の発言だけを取り出す。"""
    result: list[Message] = []
    for root, marker, extract, source in (
        (CLAUDE, b'"type":"user"', _claude_texts, "claude"),
        (CODEX, b'"role":"user"', _codex_texts, "codex"),
    ):
        if not root.exists():
            continue
        for path in root.rglob("*.jsonl"):
            if datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) < since:
                continue
            with path.open("rb") as f:
                for raw in f:
                    if marker not in raw:
                        continue
                    try:
                        entry = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    at = _parse_time(entry.get("timestamp", ""))
                    if at is None or at < since:
                        continue
                    for text in extract(entry):
                        # 差し込まれた指示やコマンドの出力（<...> で始まる）は利用者の発言ではない
                        if text.strip() and not text.lstrip().startswith("<"):
                            result.append(Message(at, text, source))
    result.sort(key=lambda m: m.at)
    return result


def _best_match(row: dict, candidates: list[Message]) -> tuple[Message | None, float]:
    inserted = _normalize(row["inserted_text"])
    best, best_ratio = None, 0.0
    for message in candidates:
        sent = _normalize(message.text)
        # 送った文は、貼った本文の前後に手で書き足したものでもある。貼った本文に最も近い部分で比べる
        matcher = SequenceMatcher(None, inserted, sent, autojunk=False)
        blocks = [b for b in matcher.get_matching_blocks() if b.size]
        if not blocks:
            continue
        start = blocks[0].b
        end = blocks[-1].b + blocks[-1].size
        ratio = SequenceMatcher(None, inserted, sent[start:end], autojunk=False).ratio()
        if ratio > best_ratio:
            best, best_ratio = Message(message.at, sent[start:end], message.source), ratio
    return best, best_ratio


def pairs(since: datetime) -> list[dict]:
    rows = history(since)
    sent = messages(since)
    result = []
    cursor = 0
    for row in rows:
        while cursor < len(sent) and sent[cursor].at < row["at_dt"] - timedelta(seconds=5):
            cursor += 1
        window = [m for m in sent[cursor : cursor + 50] if m.at <= row["at_dt"] + WINDOW]
        match, ratio = _best_match(row, window)
        inserted = _normalize(row["inserted_text"])
        if match is None or ratio < MATCH_RATIO:
            kind = "unmatched"
        elif match.text == inserted:
            kind = "same"
        elif ratio >= SMALL_EDIT_RATIO:
            kind = "small_edit"
        else:
            kind = "rewrite"
        result.append({
            "at": row["at"], "target_app": row.get("target_app"), "inserted": inserted,
            "sent": match.text if match and ratio >= MATCH_RATIO else None,
            "source": match.source if match else None, "ratio": round(ratio, 3), "kind": kind,
        })
    return result


def replacements(pair: dict) -> list[tuple[str, str]]:
    """小さな直しの中の置き換え（認識した表記 → 直した表記）。辞書の候補になる。"""
    matcher = SequenceMatcher(None, pair["inserted"], pair["sent"], autojunk=False)
    return [
        (pair["inserted"][i1:i2], pair["sent"][j1:j2])
        for op, i1, i2, j1, j2 in matcher.get_opcodes()
        if op == "replace" and 0 < i2 - i1 <= 12 and 0 < j2 - j1 <= 12
    ]


def added_question_marks(pair: dict) -> int:
    """貼った本文では「。」か記号なしだった文末を、送る前に「？」にした数。"""
    inserted = re.split(r"(?<=[。？?！!])", pair["inserted"])
    sent = pair["sent"]
    count = 0
    for sentence in inserted:
        body = re.sub(r"[。？?！!\s]+$", "", sentence)
        if len(body) >= 4 and not sentence.rstrip().endswith(("？", "?")):
            if re.search(re.escape(body[-6:]) + r"\s*[？?]", sent):
                count += 1
    return count


def main() -> None:
    since = datetime(2026, 9, 6, tzinfo=timezone(timedelta(hours=9)))
    result = pairs(since)
    voxdata.DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    out = voxdata.DATA / "corrections.jsonl"
    out.write_text("".join(json.dumps(p, ensure_ascii=False) + "\n" for p in result), encoding="utf-8")
    out.chmod(0o600)
    kinds = Counter(p["kind"] for p in result)
    print(f"vox の貼り付け {len(result)} 件: " + ", ".join(f"{k} {v}" for k, v in kinds.most_common()))
    print("送り先:", dict(Counter(p["target_app"] for p in result).most_common(4)))
    small = [p for p in result if p["kind"] == "small_edit"]
    print(f"手で「？」にした文末: {sum(added_question_marks(p) for p in small + [p for p in result if p['kind'] == 'rewrite'])}")
    common = Counter(r for p in small for r in replacements(p)).most_common(25)
    print("よくある置き換え（認識 → 直した表記）:")
    for (before, after), n in common:
        print(f"  {n:3d}  {before} → {after}")
    print(f"書き出し: {out}")


if __name__ == "__main__":
    main()

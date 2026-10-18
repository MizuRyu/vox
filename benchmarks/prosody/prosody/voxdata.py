"""vox が保存した録音（ADR-026）と、このツールの録音を読む。"""

from __future__ import annotations

import json
import re
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np

import os

VOX_ROOT = Path.home() / "Library/Application Support/vox/recordings"
# 本人の声・ラベル・学習した重みはリポジトリの外に置く（ADR-029）。検査や別の置き場は環境変数で替える。
DATA = Path(os.environ.get("VOX_PROSODY_DATA") or Path.home() / "Library/Application Support/vox/prosody")
CONTRAST = DATA / "contrast"
LABELS = DATA / "labels.jsonl"

RECORDING_ID = re.compile(r"^\d{8}/\d{6}-\d{2}$")
SENTENCE_END = re.compile(r"[。？！?!]")


@dataclass(frozen=True)
class Sentence:
    index: int
    text: str
    # 文末の音声上の時刻（秒）。時刻の無い古い録音では None（音量から推定する）。
    end_s: float | None
    # 文末の語の長さ（秒）。引き延ばしの手がかり。
    final_piece_s: float | None
    # 文の最初の語の音声上の開始（秒）。文全体を聞き直すのに使う。
    start_s: float | None = None


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as wf:
        if (wf.getframerate(), wf.getnchannels(), wf.getsampwidth()) != (16_000, 1, 2):
            raise ValueError(f"16kHz・モノラル・Int16 ではない: {path}")
        raw = wf.readframes(wf.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0


def recording_ids() -> list[str]:
    if not VOX_ROOT.exists():
        return []
    ids = [f"{p.parent.name}/{p.stem}" for p in VOX_ROOT.glob("*/*.json")]
    return sorted(i for i in ids if RECORDING_ID.match(i) and (VOX_ROOT / f"{i}.wav").exists())


def recording_paths(recording: str) -> tuple[Path, Path]:
    if not RECORDING_ID.match(recording):
        raise ValueError(f"録音の ID ではない: {recording}")
    return VOX_ROOT / f"{recording}.wav", VOX_ROOT / f"{recording}.json"


def sentences(sidecar: dict) -> list[Sentence]:
    """確定した語の区間（schema 2 の segments）から文に分ける。無ければ本文全体を 1 文にする。"""
    segments = sidecar.get("segments") or []
    if not segments:
        text = (sidecar.get("history") or {}).get("raw_text") or ""
        return [Sentence(0, text.strip(), None, None, None)] if text.strip() else []

    result: list[Sentence] = []
    buffer = ""
    first_start: float | None = None
    last_end: float | None = None
    last_piece: float | None = None
    for piece in segments:
        text = piece.get("text") or ""
        start, end = piece.get("start_s"), piece.get("end_s")
        if start is not None and end is not None and text.strip():
            last_end, last_piece = end, end - start
            if first_start is None:
                first_start = start
        cursor = 0
        for match in SENTENCE_END.finditer(text):
            buffer += text[cursor : match.end()]
            cursor = match.end()
            if buffer.strip():
                result.append(Sentence(len(result), buffer.strip(), last_end, last_piece, first_start))
            buffer = ""
            first_start = None
        buffer += text[cursor:]
    if buffer.strip():
        result.append(Sentence(len(result), buffer.strip(), last_end, last_piece, first_start))
    return result


def load_sidecar(recording: str) -> dict:
    _, json_path = recording_paths(recording)
    return json.loads(json_path.read_text(encoding="utf-8"))


def load_labels() -> list[dict]:
    if not LABELS.exists():
        return []
    latest: dict[tuple[str, int], dict] = {}
    for line in LABELS.read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            latest[(row["recording"], row["sentence_index"])] = row  # 付け直しは後の行が勝つ
    return list(latest.values())

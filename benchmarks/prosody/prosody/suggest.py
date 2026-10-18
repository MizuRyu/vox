"""ラベル付け画面の推奨。文字だけで疑問と言える文末（vox の ADR-028 と同じ形）は「？」、
それ以外は学習した分類器の確率で決める。推奨は判断を楽にするためのもので、正解ではない。"""

from __future__ import annotations

import pickle
import re
from functools import lru_cache

import numpy as np

from prosody import dataset, features, voxdata

# vox 本体の QuestionMarkPass と同じ形（丁寧語の疑問と「っけ」）
TEXT_QUESTION = re.compile(r"(?:(?:です|ます|でした|ました|ません|でしょう)か(?:ね)?|っけ)[。？?\s　]*$")
# 読み分けは「？」と「。」がほぼ半々で、学習した確率は自然な発話より「？」寄りに出る。
# 自然な発話のラベルで決め直すまでの仮の値。
MODEL_THRESHOLD = 0.7


@lru_cache(maxsize=1)
def _model(modified: float):
    with (voxdata.DATA / "suggester.pkl").open("rb") as f:
        return pickle.load(f)


def _loaded():
    path = voxdata.DATA / "suggester.pkl"
    return _model(path.stat().st_mtime) if path.exists() else None


@lru_cache(maxsize=2048)
def _probability(recording: str, end_s: float, text: str, final_piece_s: float | None, modified: float) -> float | None:
    loaded = _model(modified)
    samples = dataset._vox_samples(recording)
    row = features.sentence_end(dataset._track_around(samples, end_s), end_s, text, final_piece_s)
    x = np.array([[row[name] for name in loaded["features"]]], dtype=float)
    return float(loaded["model"].predict_proba(x)[0, 1])


def question(recording: str, text: str, end_s: float | None, final_piece_s: float | None) -> dict:
    """{"mark": "q" | "s" | None, "p": 確率 | None, "by": "text" | "ending" | "model" | None}"""
    if TEXT_QUESTION.search(text):
        return {"mark": "q", "p": None, "by": "text"}
    stripped = re.sub(r"[。？?！!、\s]+$", "", text)
    if not any(pattern.search(stripped) for pattern in features.ENDINGS.values()):
        return {"mark": "s", "p": None, "by": "ending"}  # 迷いやすい語尾でなければ、ほとんど言い切り
    path = voxdata.DATA / "suggester.pkl"
    if end_s is None or not path.exists():
        return {"mark": None, "p": None, "by": None}
    try:
        p = _probability(recording, end_s, text, final_piece_s, path.stat().st_mtime)
    except (OSError, ValueError):
        return {"mark": None, "p": None, "by": None}
    return {"mark": "q" if p >= MODEL_THRESHOLD else "s", "p": p, "by": "model"}

"""読み分けの録音と、自然な発話のラベルから特徴表を作る。"""

from __future__ import annotations

import json
from functools import lru_cache

import numpy as np

from prosody import features, voxdata, yin


# 文末の特徴に要るのは te の 1.5 秒前から 0.3 秒後まで。長い録音の全体で F0 を求めない。
BEFORE_S = 1.5
AFTER_S = 0.3


@lru_cache(maxsize=64)
def _vox_samples(recording: str) -> np.ndarray:
    wav, _ = voxdata.recording_paths(recording)
    return voxdata.read_wav(wav)


def _track_around(samples: np.ndarray, te: float) -> yin.Track:
    start = max(0, int((te - BEFORE_S) * yin.SAMPLE_RATE))
    end = min(len(samples), int((te + AFTER_S) * yin.SAMPLE_RATE))
    track = yin.track(samples[start:end])
    return yin.Track(track.times + start / yin.SAMPLE_RATE, track.f0, track.rms, track.aperiodicity)


def rows() -> list[dict]:
    """1 行 = 1 文末。`want_question` / `want_ellipsis` は True / False / None（保留・未付与）。"""
    return _contrast_rows() + _natural_rows()


def _contrast_rows() -> list[dict]:
    result = []
    for meta_path in sorted(voxdata.CONTRAST.glob("*.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        track = yin.track(voxdata.read_wav(meta_path.with_suffix(".wav")))
        te = features.speech_end(track.times, track.rms)
        if te is None:
            continue
        result.append(
            {
                "source": "contrast",
                "group": "contrast-" + meta["recorded_at"][:10],
                "id": meta_path.stem,
                "text": meta["text"],
                # ためらいの読みは、問いかけかどうかを決めていない（「大丈夫…」は両方ありうる）
                "want_question": None if meta["intent"] == "hesitant" else meta["intent"] == "question",
                "want_ellipsis": meta["intent"] == "hesitant",
                **features.sentence_end(track, te, meta["text"], None),
            }
        )
    return result


def _natural_rows() -> list[dict]:
    result = []
    for label in voxdata.load_labels():
        recording = label["recording"]
        try:
            samples = _vox_samples(recording)
        except (FileNotFoundError, ValueError):
            continue  # 回収された録音
        te = label.get("end_s")
        if te is None:
            te = features.speech_end(*yin.loudness(samples))
        if te is None:
            continue
        track = _track_around(samples, te)
        result.append(
            {
                "source": "natural",
                "group": "natural-" + recording[:8],
                "id": f"{recording}#{label['sentence_index']}",
                "text": label["text"],
                "want_question": label.get("want_question"),
                "want_ellipsis": label.get("want_ellipsis"),
                **features.sentence_end(track, te, label["text"], label.get("final_piece_s")),
            }
        )
    return result


def matrix(table: list[dict], columns: list[str], target: str) -> tuple[np.ndarray, np.ndarray, list[dict]]:
    """target が True / False の行だけ。保留（None）は学習にも評価にも入れない。"""
    kept = [r for r in table if r.get(target) is not None]
    x = np.array([[r[c] for c in columns] for r in kept], dtype=float).reshape(len(kept), len(columns))
    y = np.array([bool(r[target]) for r in kept])
    return x, y, kept

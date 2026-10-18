"""合成した上昇・下降の音で、読み分け → 特徴 → 学習 → 書き出しが通ることを確かめる。"""

import json
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np

from prosody import dataset, train, voxdata

SR = 16_000


def tone(end_hz: float, seconds: float = 1.2, seed: int = 0) -> np.ndarray:
    """最後の 300 ms で 200 Hz から end_hz へ動く、倍音つきの声に似た音。前後に無音。"""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * SR)) / SR
    tail = seconds - 0.3
    f = np.where(t < tail, 200.0, 200.0 + (t - tail) / 0.3 * (end_hz - 200.0))
    phase = 2 * np.pi * np.cumsum(f) / SR
    voice = 0.3 * (np.sin(phase) + 0.5 * np.sin(2 * phase) + 0.25 * np.sin(3 * phase))
    silence = np.zeros(int(0.3 * SR))
    return np.concatenate([silence, voice, silence]) + rng.normal(0, 0.002, int(seconds * SR) + 2 * len(silence))


def write_wav(path: Path, samples: np.ndarray) -> None:
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())


class PipelineTest(unittest.TestCase):
    def test_rising_and_falling_contrast_trains_and_exports(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            contrast = data / "contrast"
            contrast.mkdir()
            for i in range(30):
                for intent, end_hz in (("question", 260 + i), ("statement", 160 - i)):
                    stem = contrast / f"p{i:02d}-{intent}"
                    write_wav(stem.with_suffix(".wav"), tone(end_hz, seed=i))
                    stem.with_suffix(".json").write_text(json.dumps({
                        "text": "これでいいかな", "intent": intent,
                        "recorded_at": f"2026-10-{18 + i % 3:02d}T10:00:00",
                    }), encoding="utf-8")
            with (
                patch.object(voxdata, "DATA", data),
                patch.object(voxdata, "CONTRAST", contrast),
                patch.object(voxdata, "LABELS", data / "labels.jsonl"),
                patch.object(voxdata, "VOX_ROOT", data / "none"),
            ):
                rows = dataset.rows()
                self.assertEqual(len(rows), 60)
                rising = [r["rise_st"] for r in rows if r["want_question"]]
                falling = [r["rise_st"] for r in rows if not r["want_question"]]
                self.assertGreater(min(rising), 1.0)
                self.assertLess(max(falling), -1.0)
                train.main()
                report = (data / "report.md").read_text(encoding="utf-8")
                self.assertIn("ロジスティック回帰", report)
                model = json.loads((data / "model.json").read_text(encoding="utf-8"))
                self.assertEqual(len(model["scale_mean"]), len(model["weights"]))


class SentenceSplitTest(unittest.TestCase):
    def test_segments_split_at_sentence_marks_and_keep_last_timed_end(self):
        sidecar = {"segments": [
            {"text": "これで", "start_s": 0.1, "end_s": 0.4},
            {"text": "いいかな。", "start_s": 0.4, "end_s": 0.9},
            {"text": "次", "start_s": 1.2, "end_s": 1.4},
            {"text": "いこう", "start_s": 1.4, "end_s": 1.8},
        ]}
        sentences = voxdata.sentences(sidecar)
        self.assertEqual([s.text for s in sentences], ["これでいいかな。", "次いこう"])
        self.assertAlmostEqual(sentences[0].end_s, 0.9)
        self.assertAlmostEqual(sentences[0].final_piece_s, 0.5)
        self.assertAlmostEqual(sentences[1].end_s, 1.8)

    def test_old_sidecar_without_segments_is_one_sentence(self):
        sentences = voxdata.sentences({"history": {"raw_text": "合成の本文。"}})
        self.assertEqual(len(sentences), 1)
        self.assertIsNone(sentences[0].end_s)


if __name__ == "__main__":
    unittest.main()

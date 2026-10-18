"""録音とラベル付けのローカルサーバー。127.0.0.1 だけで待ち受け、データは data/ に置く。

uv run python tool/server.py [--port 8765]
"""

from __future__ import annotations

import argparse
import io
import json
import wave
import re
import sys
from datetime import datetime
from functools import lru_cache
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from prosody import features, reference, suggest, voxdata, yin  # noqa: E402

PAGE = Path(__file__).with_name("index.html")
PROMPT_ID = re.compile(r"^[a-z0-9-]{1,40}$")
INTENTS = {"question", "statement", "hesitant"}
SAVED_NAME = re.compile(r"^[a-z0-9-]{1,40}-(question|statement|hesitant)-\d{8}-\d{6}-\d{6}$")
MAX_UPLOAD = 20 * 1024 * 1024

# 読み分けの文。同じ文字で語尾の上げ下げだけを変え、音声の効き目を見る（調査 D-2）。
# hesitant を持つ文は「ためらいながら」も読む。
PROMPTS = [
    {"id": "kore-ii", "text": "これでいい", "intents": ["question", "statement"]},
    {"id": "kore-ii-kana", "text": "これでいいかな", "intents": ["question", "statement"]},
    {"id": "sou-nano", "text": "そうなの", "intents": ["question", "statement"]},
    {"id": "owatta", "text": "もう終わった", "intents": ["question", "statement"]},
    {"id": "owatta-kana", "text": "もう終わったかな", "intents": ["question", "statement"]},
    {"id": "ashita", "text": "明日でいい", "intents": ["question", "statement"]},
    {"id": "hontou", "text": "それ本当", "intents": ["question", "statement"]},
    {"id": "oite-ii", "text": "ここに置いていい", "intents": ["question", "statement"]},
    {"id": "ima-iku", "text": "今から行く", "intents": ["question", "statement"]},
    {"id": "tsukaeru", "text": "これ使える", "intents": ["question", "statement"]},
    {"id": "atteru", "text": "あれで合ってる", "intents": ["question", "statement", "hesitant"]},
    {"id": "kaerou-kana", "text": "そろそろ帰ろうかな", "intents": ["question", "statement"]},
    {"id": "daijoubu", "text": "大丈夫", "intents": ["question", "statement", "hesitant"]},
    {"id": "ame-kana", "text": "雨降るかな", "intents": ["question", "statement"]},
    {"id": "maniau", "text": "間に合う", "intents": ["question", "statement", "hesitant"]},
    {"id": "kimari", "text": "それで決まり", "intents": ["question", "statement"]},
    {"id": "keshite-ii", "text": "これ消していい", "intents": ["question", "statement"]},
    {"id": "push-kana", "text": "先にプッシュしておこうかな", "intents": ["question", "statement"]},
    {"id": "test-tooru", "text": "テスト通った", "intents": ["question", "statement", "hesitant"]},
    {"id": "review-kana", "text": "レビューお願いしてもいいかな", "intents": ["question", "statement"]},
    {"id": "sore-de-ii-no", "text": "それでいいの", "intents": ["question", "statement"]},
    {"id": "wakatta", "text": "わかった", "intents": ["question", "statement"]},
    {"id": "dekiru", "text": "今日中にできる", "intents": ["question", "statement", "hesitant"]},
    {"id": "kono-hou", "text": "こっちの方がいいかな", "intents": ["question", "statement", "hesitant"]},
    {"id": "jikkou", "text": "このまま実行していい", "intents": ["question", "statement"]},
    {"id": "tabun", "text": "たぶん大丈夫だと思う", "intents": ["statement", "hesitant"]},
    {"id": "omou", "text": "仕様はこれで合ってると思う", "intents": ["statement", "hesitant"]},
    {"id": "kamo", "text": "それが原因かもしれない", "intents": ["statement", "hesitant"]},
    {"id": "ki-ga-suru", "text": "どこかで見た気がする", "intents": ["statement", "hesitant"]},
    {"id": "jishin-nai", "text": "ちょっと自信ないんだよね", "intents": ["statement", "hesitant"]},
]


def contrast_counts() -> dict[str, int]:
    counts: dict[str, int] = {}
    for meta in voxdata.CONTRAST.glob("*.json"):
        data = json.loads(meta.read_text(encoding="utf-8"))
        key = f"{data['prompt_id']}:{data['intent']}"
        counts[key] = counts.get(key, 0) + 1
    return counts


@lru_cache(maxsize=512)
def _fallback_end(recording: str, modified: float) -> float | None:
    """時刻の無い古い録音の発話末。音量だけで推定し、録音ごとに覚えておく（modified は無効化用）。"""
    wav, _ = voxdata.recording_paths(recording)
    return features.speech_end(*yin.loudness(voxdata.read_wav(wav)))


@lru_cache(maxsize=16)
def _samples(recording: str, modified: float):
    wav, _ = voxdata.recording_paths(recording)
    return voxdata.read_wav(wav)


def _wav_bytes(samples) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(yin.SAMPLE_RATE)
        wf.writeframes((samples.clip(-1, 1) * 32767).astype("<i2").tobytes())
    return buffer.getvalue()


def _candidates_for(recording: str, labels: dict) -> list[dict]:
    try:
        sidecar = voxdata.load_sidecar(recording)
    except (OSError, ValueError):
        return []
    sentences = voxdata.sentences(sidecar)
    result = []
    for s in sentences:
        if s.end_s is None and s.index != len(sentences) - 1:
            continue  # 時刻の無い古い録音は最後の文だけ
        end_s = s.end_s
        if end_s is None:
            wav, _ = voxdata.recording_paths(recording)
            end_s = _fallback_end(recording, wav.stat().st_mtime)
        label = labels.get((recording, s.index), {})
        result.append({
            "recording": recording,
            "sentence_index": s.index,
            "text": s.text,
            "end_s": end_s,
            "final_piece_s": s.final_piece_s,
            "start_s": s.start_s,
            "priority": _priority(s.text),
            "want_question": label.get("want_question"),
            "want_ellipsis": label.get("want_ellipsis"),
            "reference_text": label.get("reference_text"),
            "reference_suggestion": reference.suggest(s.text),
            "suggestion": label.get("suggestion"),
            "labeled": bool(label),
        })
    return result


def natural_candidates() -> list[dict]:
    labels = {(r["recording"], r["sentence_index"]): r for r in voxdata.load_labels() if r["labeled_by"] == "user"}
    result = [c for recording in voxdata.recording_ids() for c in _candidates_for(recording, labels)]
    # 未ラベル → 迷いやすい語尾 → 新しい録音
    result.sort(key=lambda c: (c["labeled"], -c["priority"], [-ord(ch) for ch in c["recording"]], c["sentence_index"]))
    return result


def _priority(text: str) -> int:
    stripped = re.sub(r"[。？?！!、\s]+$", "", text)
    return 1 if any(p.search(stripped) for p in features.ENDINGS.values()) else 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:  # 本文やパスを端末に流さない
        pass

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload, status: int = HTTPStatus.OK) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def _error(self, status: int, message: str) -> None:
        self._json({"error": message}, status)

    def do_GET(self) -> None:
        url = urlparse(self.path)
        if url.path == "/":
            self._send(HTTPStatus.OK, PAGE.read_bytes(), "text/html; charset=utf-8")
        elif url.path == "/api/prompts":
            self._json({"prompts": PROMPTS, "counts": contrast_counts()})
        elif url.path == "/api/natural":
            self._json({"candidates": natural_candidates(), "vox_root_exists": voxdata.VOX_ROOT.exists()})
        elif url.path == "/api/suggest":
            self._suggest(parse_qs(url.query))
        elif url.path == "/api/clip":
            self._clip(parse_qs(url.query))
        elif url.path == "/api/audio":
            recording = (parse_qs(url.query).get("recording") or [""])[0]
            try:
                wav, _ = voxdata.recording_paths(recording)
                self._send(HTTPStatus.OK, wav.read_bytes(), "audio/wav")
            except (ValueError, OSError):
                self._error(HTTPStatus.NOT_FOUND, "録音がありません")
        else:
            self._error(HTTPStatus.NOT_FOUND, "not found")

    def _suggest(self, query: dict) -> None:
        """表示する文の推奨だけを計算する（一覧で全件の F0 を求めると遅い）。"""
        recording = (query.get("recording") or [""])[0]
        try:
            index = int((query.get("index") or [""])[0])
            candidate = next(c for c in _candidates_for(recording, {}) if c["sentence_index"] == index)
        except (ValueError, StopIteration):
            self._error(HTTPStatus.NOT_FOUND, "対象の文がありません")
            return
        self._json(suggest.question(recording, candidate["text"], candidate["end_s"], candidate["final_piece_s"]))

    def _clip(self, query: dict) -> None:
        """録音の [start, end] 秒だけを wav にして返す。ブラウザが全体を読まずに済むように。"""
        recording = (query.get("recording") or [""])[0]
        try:
            start = max(0.0, float((query.get("start") or [""])[0]))
            end = float((query.get("end") or [""])[0])
            wav, _ = voxdata.recording_paths(recording)
            samples = _samples(recording, wav.stat().st_mtime)
        except (ValueError, OSError):
            self._error(HTTPStatus.NOT_FOUND, "録音か区間が不正です")
            return
        if not 0 < end - start <= 120:
            self._error(HTTPStatus.BAD_REQUEST, "区間が不正です")
            return
        clip = samples[int(start * yin.SAMPLE_RATE) : int(end * yin.SAMPLE_RATE)]
        self._send(HTTPStatus.OK, _wav_bytes(clip), "audio/wav")

    def do_POST(self) -> None:
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_UPLOAD:
            self._error(HTTPStatus.BAD_REQUEST, "本文の大きさが不正です")
            return
        body = self.rfile.read(length)
        if url.path == "/api/contrast":
            self._save_contrast(parse_qs(url.query), body)
        elif url.path == "/api/label":
            self._save_label(body)
        else:
            self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_DELETE(self) -> None:
        url = urlparse(self.path)
        name = (parse_qs(url.query).get("name") or [""])[0]
        if url.path != "/api/contrast" or not SAVED_NAME.match(name):
            self._error(HTTPStatus.BAD_REQUEST, "消す録音の名前が不正です")
            return
        stem = voxdata.CONTRAST / name
        if not stem.with_suffix(".wav").exists():
            self._error(HTTPStatus.NOT_FOUND, "録音がありません")
            return
        for suffix in (".wav", ".json"):
            stem.with_suffix(suffix).unlink(missing_ok=True)
        self._json({"deleted": name, "counts": contrast_counts()})

    def _save_contrast(self, query: dict, body: bytes) -> None:
        prompt_id = (query.get("prompt") or [""])[0]
        intent = (query.get("intent") or [""])[0]
        prompt = next((p for p in PROMPTS if p["id"] == prompt_id), None)
        if not PROMPT_ID.match(prompt_id) or prompt is None or intent not in prompt["intents"]:
            self._error(HTTPStatus.BAD_REQUEST, "文か読み方が不正です")
            return
        if body[:4] != b"RIFF" or body[8:12] != b"WAVE":
            self._error(HTTPStatus.BAD_REQUEST, "wav ではありません")
            return
        voxdata.CONTRAST.mkdir(parents=True, exist_ok=True, mode=0o700)
        now = datetime.now()
        stem = voxdata.CONTRAST / f"{prompt_id}-{intent}-{now:%Y%m%d-%H%M%S-%f}"
        stem.with_suffix(".wav").write_bytes(body)
        try:
            voxdata.read_wav(stem.with_suffix(".wav"))
        except ValueError as error:
            stem.with_suffix(".wav").unlink()
            self._error(HTTPStatus.BAD_REQUEST, str(error))
            return
        stem.with_suffix(".json").write_text(json.dumps({
            "prompt_id": prompt_id, "text": prompt["text"], "intent": intent,
            "recorded_at": now.isoformat(timespec="seconds"),
        }, ensure_ascii=False), encoding="utf-8")
        self._json({"saved": stem.name, "counts": contrast_counts()})

    def _save_label(self, body: bytes) -> None:
        try:
            row = json.loads(body)
            recording = row["recording"]
            voxdata.recording_paths(recording)
            index = int(row["sentence_index"])
            candidate = next(
                c for c in _candidates_for(recording, {})
                if c["sentence_index"] == index
            )
        except (ValueError, KeyError, StopIteration, TypeError):
            self._error(HTTPStatus.BAD_REQUEST, "対象の文がありません")
            return
        for key in ("want_question", "want_ellipsis"):
            if row.get(key) not in (True, False, None):
                self._error(HTTPStatus.BAD_REQUEST, f"{key} が不正です")
                return
        reference = row.get("reference_text")
        if reference is not None and (not isinstance(reference, str) or len(reference) > 4000):
            self._error(HTTPStatus.BAD_REQUEST, "正しい文が不正です")
            return
        # 認識した文のままなら、正解の文としては残さない（書き換えた文だけが正解の情報を持つ）
        if reference is not None and reference.strip() in ("", candidate["text"]):
            reference = None
        record = {
            "recording": recording, "sentence_index": index, "text": candidate["text"],
            "end_s": candidate["end_s"], "final_piece_s": candidate["final_piece_s"],
            "want_question": row.get("want_question"), "want_ellipsis": row.get("want_ellipsis"),
            "reference_text": reference.strip() if reference else None,
            # 推奨に引っ張られたかを後で調べるため、出した推奨と、それをそのまま受けたかを残す
            "suggestion": row.get("suggestion") if isinstance(row.get("suggestion"), dict) else None,
            "accepted_suggestion": row.get("accepted_suggestion") is True,
            # 正しい文を利用者が書き換えたか（False なら修正案と文末の記号の自動合わせだけ）
            "reference_edited": row.get("reference_edited") is True,
            "labeled_at": datetime.now().isoformat(timespec="seconds"),
        }
        voxdata.DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
        with voxdata.LABELS.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self._json({"saved": True})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{args.port} を開いてください（Ctrl+C で終了）。データ: {voxdata.DATA}")
    server.serve_forever()


if __name__ == "__main__":
    main()

"""ツールのサーバーを一時フォルダの data/ と vox 録音で動かし、受け取りと拒否を確かめる。"""

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import wave
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import numpy as np

from prosody import voxdata
from tests.test_pipeline import tone, write_wav
from tool import server


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.data = root / "data"
        self.vox = root / "vox"
        day = self.vox / "20261018"
        day.mkdir(parents=True)
        write_wav(day / "100000-01.wav", tone(260))
        (day / "100000-01.json").write_text(json.dumps({
            "schema_version": 2,
            "segments": [
                {"text": "これで", "start_s": 0.3, "end_s": 0.8},
                {"text": "いいかな。", "start_s": 0.8, "end_s": 1.5},
            ],
            "history": {"raw_text": "これでいいかな。"},
        }), encoding="utf-8")
        self.patches = [
            patch.object(voxdata, "DATA", self.data),
            patch.object(voxdata, "CONTRAST", self.data / "contrast"),
            patch.object(voxdata, "LABELS", self.data / "labels.jsonl"),
            patch.object(voxdata, "AGENT_LABELS", self.data / "agent_labels.jsonl"),
            patch.object(voxdata, "VOX_ROOT", self.vox),
        ]
        for p in self.patches:
            p.start()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def request(self, path, body=None, method=None):
        req = urllib.request.Request(
            self.base + path, data=body, method=method or ("POST" if body is not None else "GET"))
        try:
            with urllib.request.urlopen(req) as res:
                return res.status, res.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def wav_bytes(self):
        path = Path(self.tmp.name) / "upload.wav"
        write_wav(path, tone(240))
        return path.read_bytes()

    def test_page_and_prompts(self):
        status, body = self.request("/")
        self.assertEqual(status, 200)
        self.assertIn("vox 韻律ラベル", body.decode())
        status, body = self.request("/api/prompts")
        self.assertEqual(len(json.loads(body)["prompts"]), len(server.PROMPTS))

    def test_contrast_upload_is_saved_and_bad_input_is_rejected(self):
        status, body = self.request("/api/contrast?prompt=kore-ii&intent=question", self.wav_bytes())
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body)["counts"], {"kore-ii:question": 1})
        self.assertEqual(len(list((self.data / "contrast").glob("*.wav"))), 1)
        # この文に「ためらい」の読み方は無い
        self.assertEqual(self.request("/api/contrast?prompt=kore-ii&intent=hesitant", self.wav_bytes())[0], 400)
        self.assertEqual(self.request("/api/contrast?prompt=kore-ii&intent=question", b"not a wav file")[0], 400)
        self.assertEqual(self.request("/api/contrast?prompt=../x&intent=question", self.wav_bytes())[0], 400)
        saved = json.loads(body)["saved"]
        self.assertEqual(self.request("/api/contrast?name=../../x", method="DELETE")[0], 400)
        status, body = self.request(f"/api/contrast?name={saved}", method="DELETE")
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body)["counts"], {})
        self.assertEqual(list((self.data / "contrast").iterdir()), [])
        self.assertEqual(self.request(f"/api/contrast?name={saved}", method="DELETE")[0], 404)

    def test_natural_candidates_label_and_audio(self):
        status, body = self.request("/api/natural")
        candidates = json.loads(body)["candidates"]
        self.assertEqual([c["text"] for c in candidates], ["これでいいかな。"])
        self.assertAlmostEqual(candidates[0]["end_s"], 1.5)
        label = {"recording": "20261018/100000-01", "sentence_index": 0, "want_question": True, "want_ellipsis": False}
        self.assertEqual(self.request("/api/label", json.dumps(label).encode())[0], 200)
        saved = [json.loads(line) for line in (self.data / "labels.jsonl").read_text().splitlines()]
        self.assertEqual(saved[0]["end_s"], 1.5)
        self.assertTrue(json.loads(self.request("/api/natural")[1])["candidates"][0]["labeled"])
        self.assertEqual(self.request("/api/audio?recording=20261018/100000-01")[0], 200)
        self.assertEqual(candidates[0]["start_s"], 0.3)
        status, clip = self.request("/api/clip?recording=20261018/100000-01&start=1.0&end=1.5")
        self.assertEqual(status, 200)
        self.assertEqual(len(clip), 44 + int(0.5 * 16000) * 2)
        self.assertEqual(self.request("/api/clip?recording=20261018/100000-01&start=2&end=1")[0], 400)
        self.assertEqual(self.request("/api/clip?recording=../x&start=0&end=1")[0], 404)
        self.assertEqual(self.request("/api/audio?recording=../../etc/passwd")[0], 404)
        edited = dict(label, reference_text="これで、いいかな？")
        self.assertEqual(self.request("/api/label", json.dumps(edited).encode())[0], 200)
        unchanged = dict(label, reference_text="これでいいかな。")
        self.assertEqual(self.request("/api/label", json.dumps(unchanged).encode())[0], 200)
        saved = [json.loads(line) for line in (self.data / "labels.jsonl").read_text().splitlines()]
        self.assertEqual([r["reference_text"] for r in saved], [None, "これで、いいかな？", None])
        status, body = self.request("/api/suggest?recording=20261018/100000-01&index=0")
        self.assertEqual(status, 200, body)
        self.assertIn(json.loads(body)["by"], ("model", None))  # 「かな」は文字では決めない。重みが無ければ推奨なし
        accepted = dict(label, suggestion={"mark": "s", "p": 0.2, "by": "model"}, accepted_suggestion=True)
        self.assertEqual(self.request("/api/label", json.dumps(accepted).encode())[0], 200)
        last = json.loads((self.data / "labels.jsonl").read_text().splitlines()[-1])
        self.assertTrue(last["accepted_suggestion"])
        self.assertEqual(last["suggestion"]["mark"], "s")
        self.assertEqual(self.request("/api/suggest?recording=20261018/100000-01&index=9")[0], 404)
        bad = dict(label, sentence_index=5)
        self.assertEqual(self.request("/api/label", json.dumps(bad).encode())[0], 400)


if __name__ == "__main__":
    unittest.main()

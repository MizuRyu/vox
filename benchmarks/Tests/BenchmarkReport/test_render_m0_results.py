import importlib.util
import json
import math
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "scripts" / "render_m0_results.py"
SPEC = importlib.util.spec_from_file_location("render_m0_results", SCRIPT)
assert SPEC and SPEC.loader
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


def record(engine="apple", dataset="custom", **overrides):
    value = {
        "schema_version": 1,
        "engine": engine,
        "dataset": dataset,
        "sample_id": "sample-1",
        "reference": "こんにちは",
        "hypothesis": "こんにちは",
        "first_token_latency_ms": 350,
        "final_latency_ms": 500,
        "cer": 0,
        "idle_rss_bytes": 100,
        "peak_rss_bytes": 200,
        "model_load_first_ms": 600,
        "model_load_warm_ms": 50,
        "error": None,
    }
    value.update(overrides)
    return value


class BenchmarkReportTests(unittest.TestCase):
    def test_summary_counts_successes_over_total_and_keeps_none_latency(self):
        summary = REPORT.summarize(
            [
                record(first_token_latency_ms=None),
                record(sample_id="sample-2", error="timeout"),
            ],
            "custom",
            "apple",
        )

        self.assertEqual(summary["n"], 1)
        self.assertEqual(summary["total"], 2)
        self.assertIsNone(summary["first"])

    def test_all_failures_are_present_and_distinct_from_unmeasured(self):
        failed = REPORT.summarize(
            [record(error="timeout"), record(sample_id="sample-2", error="crash")],
            "custom",
            "apple",
        )
        missing = REPORT.summarize([], "custom", "apple")

        self.assertEqual((failed["n"], failed["total"]), (0, 2))
        self.assertIsNone(failed["cer"])
        self.assertIsNone(missing)
        rendered, _ = REPORT.table(
            [record(error="timeout"), record(sample_id="sample-2", error="crash")]
        )
        self.assertIn("n=0/2", rendered)
        self.assertIn("全件失敗", rendered)
        self.assertIn("未測定", rendered)

    def test_decision_is_measurement_only_for_every_input(self):
        rendered = REPORT.decision({})

        self.assertIn("集計のみ", rendered)
        self.assertIn("ADR-010", rendered)
        self.assertIn("M0確定遅延", rendered)
        self.assertNotIn("案 A を推奨", rendered)
        self.assertNotIn("案 B を推奨", rendered)

    def test_legacy_threshold_values_are_reported_without_deciding(self):
        rendered, _ = REPORT.table(
            [
                record(first_token_latency_ms=399),
                record(
                    engine="nemotron", sample_id="sample-2", first_token_latency_ms=401
                ),
            ]
        )

        self.assertIn("399.0 ms", rendered)
        self.assertIn("401.0 ms", rendered)
        self.assertIn("集計", REPORT.decision({}))

    def test_invalid_numeric_measurement_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "first_token_latency_ms"):
            REPORT.validate_record(record(first_token_latency_ms=math.nan), "fixture", 1)
        with self.assertRaisesRegex(ValueError, "peak_rss_bytes"):
            REPORT.validate_record(record(peak_rss_bytes=-1), "fixture", 1)

    def test_load_records_rejects_invalid_json_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            path.write_text(
                json.dumps(record(first_token_latency_ms=float("nan"))) + "\n"
            )

            with self.assertRaises(ValueError):
                REPORT.load_records([path])

    def test_parser_uses_measurements_document_by_default(self):
        parser = REPORT.build_parser()

        args = parser.parse_args(["--input", "results.jsonl"])

        self.assertEqual(args.document, Path("benchmarks/m0/results/m0-results.md"))


if __name__ == "__main__":
    unittest.main()

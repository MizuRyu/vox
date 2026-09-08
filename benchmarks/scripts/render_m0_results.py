#!/usr/bin/env python3
"""Aggregate M0 JSONL measurements into the table and decision in m0-results.md."""

from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path

from jiwer import cer


ENGINES = {
    "apple": "案 A: Apple `SpeechTranscriber`",
    "nemotron": "案 B: Nemotron 3.5 multilingual @ 560 ms",
    "parakeet": "参考: Parakeet 0.6B Japanese",
}
DATASETS = {"custom": "自作 100 文", "jsut": "JSUT basic5000"}
MEASUREMENT_FIELDS = (
    "first_token_latency_ms",
    "final_latency_ms",
    "idle_rss_bytes",
    "peak_rss_bytes",
    "model_load_first_ms",
    "model_load_warm_ms",
    "cer",
)


def validate_record(record: dict, path: str | Path, line_number: int) -> None:
    for field in MEASUREMENT_FIELDS:
        value = record.get(field)
        if value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"{path}:{line_number}: {field} must be a non-negative number or null")
        if not math.isfinite(float(value)) or value < 0:
            raise ValueError(f"{path}:{line_number}: {field} must be a non-negative finite number or null")


def load_records(paths: list[Path]) -> list[dict]:
    records: list[dict] = []
    for path in paths:
        for line_number, line in enumerate(path.read_text().splitlines(), start=1):
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("schema_version") != 1:
                raise ValueError(f"{path}:{line_number}: unsupported schema_version")
            validate_record(record, path, line_number)
            records.append(record)
    return records


def median(values: list[float | int | None]) -> float | None:
    measured = [float(value) for value in values if value is not None]
    return statistics.median(measured) if measured else None


def milliseconds(value: float | None) -> str:
    return "—" if value is None else f"{value:.1f} ms"


def megabytes(value: float | None) -> str:
    return "—" if value is None else f"{value / 1024 / 1024:.1f} MB"


def percentage(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.2f}%"


def summarize(records: list[dict], dataset: str, engine: str) -> dict | None:
    matching = [
        row
        for row in records
        if row.get("dataset") == dataset and row.get("engine") == engine
    ]
    if not matching:
        return None
    rows = [row for row in matching if not row.get("error")]
    summary = {
        "n": len(rows),
        "total": len(matching),
        "first": None,
        "final": None,
        "cer": None,
        "idle": None,
        "peak": None,
        "first_load": None,
        "warm_load": None,
    }
    if not rows:
        return summary
    references = [row["reference"] for row in rows]
    hypotheses = [row["hypothesis"] for row in rows]
    summary.update({
        "first": median([row.get("first_token_latency_ms") for row in rows]),
        "final": median([row.get("final_latency_ms") for row in rows]),
        "cer": cer(references, hypotheses),
        "idle": median([row.get("idle_rss_bytes") for row in rows]),
        "peak": max((row.get("peak_rss_bytes") or 0 for row in rows), default=0) or None,
        "first_load": median([row.get("model_load_first_ms") for row in rows]),
        "warm_load": median([row.get("model_load_warm_ms") for row in rows]),
    })
    return summary


def table(records: list[dict]) -> tuple[str, dict[tuple[str, str], dict | None]]:
    summaries: dict[tuple[str, str], dict | None] = {}
    lines = [
        "| データセット | エンジン | 初出遅延（中央値） | 確定遅延（中央値） | aggregate CER | 待機中央値 / peak RSS | model load 初回 / 2回目（中央値） |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for dataset in DATASETS:
        for engine in ENGINES:
            summary = summarize(records, dataset, engine)
            summaries[(dataset, engine)] = summary
            if summary is None:
                first = "対象外" if engine == "parakeet" else "未測定"
                lines.append(
                    f"| {DATASETS[dataset]} | {ENGINES[engine]} | {first} | 未測定 | 未測定 | 未測定 | 未測定 |"
                )
                continue
            status = f"n={summary['n']}/{summary['total']}"
            if summary["n"] == 0:
                status += "（全件失敗）"
            first = "対象外" if engine == "parakeet" else milliseconds(summary["first"])
            lines.append(
                "| "
                + " | ".join(
                    [
                        f"{DATASETS[dataset]} ({status})",
                        ENGINES[engine],
                        first,
                        milliseconds(summary["final"]),
                        percentage(summary["cer"]),
                        f"{megabytes(summary['idle'])} / {megabytes(summary['peak'])}",
                        f"{milliseconds(summary['first_load'])} / {milliseconds(summary['warm_load'])}",
                    ]
                )
                + " |"
            )
    return "\n".join(lines), summaries


def decision(summaries: dict[tuple[str, str], dict | None]) -> str:
    return (
        "**集計のみ。採用判断は ADR-010 に基づく実発話/アプリ計測で行う。**\n\n"
        "M0確定遅延はアプリ貼付完了と異なる。未測定は未測定として扱う。"
    )


def replace_section(document: str, start: str, end: str, body: str) -> str:
    before, separator, remainder = document.partition(start)
    if not separator:
        raise ValueError(f"missing marker: {start}")
    _, separator, after = remainder.partition(end)
    if not separator:
        raise ValueError(f"missing marker: {end}")
    return f"{before}{start}\n{body}\n{end}{after}"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, nargs="+", required=True)
    parser.add_argument("--document", type=Path, default=Path("benchmarks/m0/results/m0-results.md"))
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    records = load_records(args.input)
    rendered_table, summaries = table(records)
    document = args.document.read_text()
    document = replace_section(document, "<!-- M0_TABLE_START -->", "<!-- M0_TABLE_END -->", rendered_table)
    document = replace_section(
        document,
        "<!-- M0_DECISION_START -->",
        "<!-- M0_DECISION_END -->",
        decision(summaries),
    )
    args.document.write_text(document)
    print(f"updated {args.document} from {len(records)} record(s)")


if __name__ == "__main__":
    main()

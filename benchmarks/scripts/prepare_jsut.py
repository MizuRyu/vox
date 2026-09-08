#!/usr/bin/env python3
"""Download and normalize JSUT basic5000, then write an M0 TSV manifest."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

import soundfile
from huggingface_hub import hf_hub_download


REPO_ID = "FluidInference/JSUT-basic5000"


def parse_transcripts(contents: str, limit: int) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for line in contents.splitlines():
        if not line.strip():
            continue
        sample_id, separator, reference = line.partition(":")
        if not separator:
            raise ValueError(f"invalid transcript line: {line}")
        entries.append((sample_id.strip(), reference.strip()))
        if len(entries) == limit:
            break
    return entries


def normalize(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_f32le",
            str(destination),
        ],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=Path("benchmarks/m0/jsut"))
    parser.add_argument("--limit", type=int, default=5000)
    args = parser.parse_args()
    if args.limit < 1 or args.limit > 5000:
        parser.error("--limit must be between 1 and 5000")

    transcript_path = Path(
        hf_hub_download(
            repo_id=REPO_ID,
            repo_type="dataset",
            filename="basic5000/transcript_utf8.txt",
        )
    )
    entries = parse_transcripts(transcript_path.read_text(), args.limit)
    audio_dir = args.output_dir / "audio"
    manifest_path = args.output_dir / "jsut.tsv"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)

    rows = ["id\tdataset\taudio\treference\tspeech_start_ms\tspeech_end_ms"]
    for index, (sample_id, reference) in enumerate(entries, start=1):
        source = Path(
            hf_hub_download(
                repo_id=REPO_ID,
                repo_type="dataset",
                filename=f"basic5000/wav/{sample_id}.wav",
            )
        )
        destination = audio_dir / f"{sample_id}.wav"
        if not destination.exists():
            normalize(source, destination)
        duration_ms = round(soundfile.info(destination).duration * 1000, 3)
        relative_audio = destination.relative_to(manifest_path.parent)
        rows.append(
            f"{sample_id}\tjsut\t{relative_audio}\t{reference}\t0\t{duration_ms}"
        )
        print(f"[{index}/{len(entries)}] {sample_id}")

    manifest_path.write_text("\n".join(rows) + "\n")
    print(f"wrote {manifest_path} ({len(entries)} samples)")


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: benchmarks/scripts/prepare_m0_audio.sh INPUT OUTPUT.wav" >&2
  exit 64
fi

input=$1
output=$2
mkdir -p "$(dirname "$output")"
ffmpeg -hide_banner -loglevel error -y -i "$input" -ar 16000 -ac 1 -c:a pcm_f32le "$output"
ffprobe -v error -select_streams a:0 \
  -show_entries stream=sample_rate,channels,codec_name \
  -of default=noprint_wrappers=1 "$output"

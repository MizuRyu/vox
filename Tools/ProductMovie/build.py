#!/usr/bin/env python3
"""Render and validate the localized product movie with native macOS tools."""

import argparse
import datetime
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent


def run(command, log, *, capture=False):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    log.write(result.stdout + result.stderr)
    log.flush()
    if result.returncode:
        raise RuntimeError(f"{command[0]} exited with {result.returncode}; see {log.name}")
    return result.stdout if capture else None


def probe(path, log):
    return json.loads(run([
        "ffprobe", "-v", "error", "-count_frames", "-show_entries",
        "format=duration,size:stream=codec_type,codec_name,width,height,nb_read_frames",
        "-of", "json", str(path),
    ], log, capture=True))


def validate(folder, stem, duration, log):
    movie = folder / f"{stem}.mp4"
    gif = folder / f"{stem}.gif"
    info = probe(movie, log)
    video = next(stream for stream in info["streams"] if stream["codec_type"] == "video")
    assert (video["width"], video["height"], int(video["nb_read_frames"])) == (1920, 1080, round(duration * 30))
    assert any(stream["codec_type"] == "audio" for stream in info["streams"])
    assert abs(float(info["format"]["duration"]) - duration) < 0.1
    run(["ffmpeg", "-v", "error", "-xerror", "-i", str(movie), "-f", "null", "-"], log)
    animation = probe(gif, log)
    stream = animation["streams"][0]
    assert (stream["width"], stream["height"], int(stream["nb_read_frames"])) == (800, 450, round(duration * 10))
    assert abs(float(animation["format"]["duration"]) - duration) < 0.1
    data = movie.read_bytes()
    assert data.index(b"moov") < data.index(b"mdat"), "MP4 must support progressive playback"
    assert (folder / f"{stem}.png").is_file()
    return {"movie": info, "gif": animation}


def render_locale(locale, spec, config, work, log):
    folder = work / locale
    folder.mkdir(exist_ok=True)
    native = [str(work / "render"), str(config), locale, str(folder)]
    run(native + ["--stills"], log)
    run(native, log)
    stem = f"{spec['slug']}-demo-{locale}"
    run([
        "ffmpeg", "-y", "-v", "error", "-i", str(folder / "silent.mp4"),
        "-i", str(work / "music.wav"), "-c:v", "copy", "-c:a", "aac", "-b:a", "128k",
        "-af", "loudnorm=I=-24:TP=-3:LRA=7", "-movflags", "+faststart",
        "-t", str(spec["duration"]), str(folder / f"{stem}.mp4"),
    ], log)
    run([
        "ffmpeg", "-y", "-v", "error", "-i", str(folder / "silent.mp4"), "-filter_complex",
        "[0:v]fps=10,scale=800:-1:flags=lanczos,split[a][b];"
        "[a]palettegen=max_colors=96:stats_mode=diff[p];"
        "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
        "-loop", "0", str(folder / f"{stem}.gif"),
    ], log)
    shutil.copyfile(folder / "poster.png", folder / f"{stem}.png")
    return folder, stem, validate(folder, stem, spec["duration"], log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locale", choices=["ja", "en", "all"], default="all")
    parser.add_argument("--config", type=Path, default=SOURCE / "movie.json")
    parser.add_argument("--output", type=Path, default=ROOT / "images")
    parser.add_argument("--check", action="store_true", help="Validate existing assets without rendering")
    args = parser.parse_args()
    config = args.config.resolve()
    spec = json.loads(config.read_text())
    assert 0 < spec["duration"] <= 120
    assert len(spec["sceneStarts"]) == 6 and spec["sceneStarts"][0] == 0
    assert spec["sceneStarts"] == sorted(set(spec["sceneStarts"]))
    assert spec["sceneStarts"][-1] < spec["duration"]
    assert spec["slug"].isascii() and spec["slug"].replace("-", "").isalnum()
    locales = ["ja", "en"] if args.locale == "all" else [args.locale]
    work = ROOT / "z-ai" / f"{datetime.date.today().isoformat()}-product-movie"
    work.mkdir(parents=True, exist_ok=True)
    results = {}
    with (work / "build.log").open("w") as log:
        if args.check:
            for locale in locales:
                stem = f"{spec['slug']}-demo-{locale}"
                results[locale] = validate(args.output, stem, spec["duration"], log)
        else:
            build = ["swift", "build", "--package-path", str(SOURCE), "--scratch-path", str(work / "swift-build"), "-c", "release", "-j", "2"]
            run(build + ["--product", "product-movie"], log)
            binary_folder = run(build + ["--show-bin-path"], log, capture=True).strip()
            shutil.copyfile(Path(binary_folder) / "product-movie", work / "render")
            (work / "render").chmod(0o755)
            run([sys.executable, str(SOURCE / "music.py"), str(work / "music.wav"), str(spec["duration"])], log)
            rendered = [render_locale(locale, spec, config, work, log) for locale in locales]
            args.output.mkdir(parents=True, exist_ok=True)
            for locale, (folder, stem, result) in zip(locales, rendered):
                for extension in ("mp4", "gif", "png"):
                    shutil.copyfile(folder / f"{stem}.{extension}", args.output / f"{stem}.{extension}")
                results[locale] = result
    (work / "verification.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"OK: {'checked' if args.check else 'rendered and checked'} {', '.join(locales)}; 1080p MP4 and README GIF")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, RuntimeError, StopIteration) as error:
        print(f"NG: {error or 'movie validation failed'}", file=sys.stderr)
        sys.exit(1)

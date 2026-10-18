"""文末の特徴。窓幅と集計は調査（docs/2026-10-18-chatgpt-prosody-research.md の A-2）の初期案。

基準時刻 te は文の音声上の末尾。特徴は「その時点までに得られた音声」だけから作る
（te より後ろは、無音の長さを測る 200 ms まで）。欠損は nan のまま返し、補完は学習側で行う。
"""

from __future__ import annotations

import re

import numpy as np

from prosody.yin import Track

# 文字の語尾。音声だけのモデルと、文字を足したモデルを比べるために持つ。
ENDINGS = {
    "kana": re.compile(r"かな[ぁあー]*$"),
    "no": re.compile(r"の[ー]*$"),
    "ka": re.compile(r"か[ー]*$"),
    "ne": re.compile(r"ね[ぇえー]*$"),
    "kke": re.compile(r"っけ$"),
}

ACOUSTIC = [
    "rise_st",
    "peak_rise_st",
    "tail_aperiodicity",
    "slope150_st_per_s",
    "slope300_st_per_s",
    "end_vs_context_st",
    "peak_position",
    "voiced_ratio200",
    "longest_gap200_ms",
    "last_voiced_gap_ms",
    "rms_ratio_db",
    "final_piece_ms",
]
TEXT = [f"ending_{name}" for name in ENDINGS]


def semitones(f0: np.ndarray, reference: float) -> np.ndarray:
    return 12 * np.log2(f0 / reference)


def _window(track: Track, start: float, end: float) -> np.ndarray:
    return (track.times >= start) & (track.times <= end)


def _median(values: np.ndarray) -> float:
    values = values[~np.isnan(values)]
    return float(np.median(values)) if len(values) else float("nan")


def _slope(track: Track, st: np.ndarray, start: float, end: float) -> float:
    mask = _window(track, start, end) & ~np.isnan(st)
    if mask.sum() < 4:
        return float("nan")
    return float(np.polyfit(track.times[mask], st[mask], 1)[0])


def _longest_gap_ms(voiced: np.ndarray) -> float:
    longest = current = 0
    for flag in voiced:
        current = 0 if flag else current + 1
        longest = max(longest, current)
    return longest * 10.0


# 文末の時刻は声の終わりとずれる。音量の末尾は後ろの息や雑音に落ち、Apple の語の区間末は
# 声の終わりより 0.1〜0.2 秒早いことがある（2026-10-18 の自然な発話で確認）。
# 窓は、te の 0.35 秒前から最大 0.5 秒後（次の文の頭まで）で最後に F0 が取れた位置に合わせる。
# もとの te との差は last_voiced_gap_ms に残す（負なら te の後ろまで声が続いた）。
VOICED_END_BEFORE_S = 0.35
VOICED_END_AFTER_S = 0.5
# 弱い語尾で拾う偽の F0（低すぎる・倍音の取り違え）を落とす。話者の中央値から 1 オクターブ超、
# または有声フレームの音量の中央値の 1 割未満のフレームは F0 として使わない。
PLAUSIBLE_RANGE_ST = 12.0
QUIET_RATIO = 0.1


def _plausible_f0(track: Track) -> np.ndarray:
    f0 = track.f0.copy()
    voiced = ~np.isnan(f0)
    if not voiced.any():
        return f0
    reference = float(np.median(f0[voiced]))
    loud = float(np.median(track.rms[voiced]))
    with np.errstate(invalid="ignore", divide="ignore"):
        far = np.abs(12 * np.log2(f0 / reference)) > PLAUSIBLE_RANGE_ST
    f0[voiced & (far | (track.rms < loud * QUIET_RATIO))] = np.nan
    return f0


def sentence_end(
    track: Track, te: float, text: str, final_piece_s: float | None, limit_s: float | None = None
) -> dict:
    """1 文の文末の特徴。te は秒。limit_s は次の文の頭（これより後ろの声は次の文）。"""
    f0 = _plausible_f0(track)
    voiced_all = ~np.isnan(f0)
    after = te + VOICED_END_AFTER_S if limit_s is None else min(te + VOICED_END_AFTER_S, limit_s)
    near = voiced_all & _window(track, te - VOICED_END_BEFORE_S, after)
    original_te = te
    if near.any():
        te = float(track.times[np.nonzero(near)[0][-1]])
    reference = _median(f0[voiced_all]) if voiced_all.any() else float("nan")
    st = semitones(f0, reference) if not np.isnan(reference) else f0 * np.nan

    last80 = _median(st[_window(track, te - 0.08, te)])
    before = _median(st[_window(track, te - 0.22, te - 0.12)])
    context = _median(st[_window(track, te - 1.0, te - 0.3)])

    in200 = _window(track, te - 0.2, te)
    voiced200 = voiced_all[in200]
    voiced_times = track.times[voiced_all & (track.times <= after)]

    tail = _window(track, te - 0.3, te) & voiced_all
    if tail.sum() >= 3:
        tail_st = st[tail]
        peak_position = float(np.argmax(tail_st) / max(len(tail_st) - 1, 1))
    else:
        peak_position = float("nan")

    end_rms = track.rms[_window(track, te - 0.15, te)]
    prior_rms = track.rms[_window(track, te - 0.6, te - 0.15) & voiced_all]
    if len(end_rms) and len(prior_rms) and np.mean(prior_rms) > 0:
        rms_ratio = float(20 * np.log10(max(np.mean(end_rms), 1e-6) / np.mean(prior_rms)))
    else:
        rms_ratio = float("nan")

    # 最後のモーラがかすれて F0 が取れない上げ調子のため、末尾 0.4 秒の最高点を、その手前と比べる
    peak = st[_window(track, te - 0.4, te)]
    peak = peak[~np.isnan(peak)]
    head = _median(st[_window(track, te - 0.9, te - 0.4)])
    peak_rise = float(np.percentile(peak, 90) - head) if len(peak) and not np.isnan(head) else float("nan")
    # 声の終わりから元の文末までのかすれ具合（1 に近いほど周期性が無い）
    tail_mask = _window(track, te - 0.05, max(te, original_te) + 0.1)
    tail_aperiodicity = float(np.mean(track.aperiodicity[tail_mask])) if tail_mask.any() else float("nan")

    stripped = re.sub(r"[。？?！!、\s]+$", "", text)
    features = {
        "rise_st": last80 - before,
        "peak_rise_st": peak_rise,
        "tail_aperiodicity": tail_aperiodicity,
        "slope150_st_per_s": _slope(track, st, te - 0.15, te),
        "slope300_st_per_s": _slope(track, st, te - 0.3, te),
        "end_vs_context_st": last80 - context,
        "peak_position": peak_position,
        "voiced_ratio200": float(voiced200.mean()) if len(voiced200) else 0.0,
        "longest_gap200_ms": _longest_gap_ms(voiced200),
        "last_voiced_gap_ms": float((original_te - voiced_times[-1]) * 1000) if len(voiced_times) else float("nan"),
        "rms_ratio_db": rms_ratio,
        "final_piece_ms": final_piece_s * 1000 if final_piece_s is not None else float("nan"),
    }
    for name, pattern in ENDINGS.items():
        features[f"ending_{name}"] = 1.0 if pattern.search(stripped) else 0.0
    return features


def speech_end(times: np.ndarray, rms: np.ndarray, near: float | None = None) -> float | None:
    """発話の音声上の末尾。時刻の無い古い録音で、最後の文の te の代わりに使う。

    ノイズ床（下位 20% の RMS）の 4 倍を超えた最後のフレーム。`near` があればそれ以前に限る。
    """
    if len(rms) == 0:
        return None
    floor = np.percentile(rms, 20)
    loud = rms > max(floor * 4, 1e-4)
    if near is not None:
        loud &= times <= near
    if not loud.any():
        return None
    return float(times[np.nonzero(loud)[0][-1]])

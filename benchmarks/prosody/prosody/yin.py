"""YIN による F0 推定（de Cheveigné & Kawahara 2002）。

Swift（vDSP）へ移す前提で、numpy の素直な処理だけを使う。
本番を YIN にするので、学習・評価もこの出力で行う（pYIN で学習して差し替えない）。
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 16_000
FRAME_LENGTH = 1024  # 64 ms
HOP_LENGTH = 160  # 10 ms
FMIN = 60.0
FMAX = 600.0
THRESHOLD = 0.15
# 閾値を下回る谷が無いとき、最も深い谷がこれ未満なら有声として採る（YIN 原著の「大域最小で代用」を上限つきで）。
FALLBACK_THRESHOLD = 0.3


@dataclass(frozen=True)
class Track:
    """フレームごとの F0（Hz、無声は nan）と RMS。`times` は窓の中心（秒）。"""

    times: np.ndarray
    f0: np.ndarray
    rms: np.ndarray
    aperiodicity: np.ndarray


def track(samples: np.ndarray, sr: int = SAMPLE_RATE) -> Track:
    if sr != SAMPLE_RATE:
        raise ValueError(f"16 kHz を前提にしている: {sr}")
    min_lag = int(sr / FMAX)
    max_lag = int(sr / FMIN)
    count = max(0, 1 + (len(samples) - FRAME_LENGTH) // HOP_LENGTH)
    f0 = np.full(count, np.nan)
    rms = np.zeros(count)
    aperiodicity = np.ones(count)
    width = FRAME_LENGTH - max_lag
    for i in range(count):
        frame = samples[i * HOP_LENGTH : i * HOP_LENGTH + FRAME_LENGTH]
        rms[i] = float(np.sqrt(np.mean(frame**2)))
        head = frame[:width]
        # d(τ) = Σ (x_j − x_{j+τ})² = Σx_j² + Σx_{j+τ}² − 2Σx_j·x_{j+τ}
        squares = np.concatenate(([0.0], np.cumsum(frame**2)))
        shifted = squares[width : width + max_lag + 1] - squares[: max_lag + 1]
        cross = np.correlate(frame[: width + max_lag], head, mode="valid")
        diff = np.maximum(squares[width] + shifted - 2 * cross, 0.0)
        # 累積平均で正規化した d'(τ)
        cumulative = np.cumsum(diff[1:])
        normalized = np.ones(max_lag + 1)
        normalized[1:] = diff[1:] * np.arange(1, max_lag + 1) / np.maximum(cumulative, 1e-12)
        lag = _first_dip(normalized, min_lag, max_lag)
        if lag is None:
            continue
        aperiodicity[i] = normalized[lag]
        f0[i] = sr / _parabolic(normalized, lag)
    times = (np.arange(count) * HOP_LENGTH + FRAME_LENGTH / 2) / sr
    return Track(times=times, f0=_fix_octave_jumps(f0), rms=rms, aperiodicity=aperiodicity)


# 直前の有声フレームの中央値と比べ、半分・倍（±1.5 半音）に飛んだ値だけを戻す。
# それ以外の大きな飛び（4 半音超）は、前後どちらとも続かない 1〜2 フレームなら無声にする。
OCTAVE_CONTEXT = 5
OCTAVE_TOLERANCE_ST = 1.5
ISOLATED_JUMP_ST = 4.0


def _fix_octave_jumps(f0: np.ndarray) -> np.ndarray:
    fixed = f0.copy()
    history: list[float] = []
    for i, value in enumerate(fixed):
        if np.isnan(value):
            continue
        if len(history) >= 3:
            reference = float(np.median(history[-OCTAVE_CONTEXT:]))
            distance = 12 * np.log2(value / reference)
            if abs(distance + 12) <= OCTAVE_TOLERANCE_ST:
                value *= 2
            elif abs(distance - 12) <= OCTAVE_TOLERANCE_ST:
                value /= 2
            elif abs(distance) > ISOLATED_JUMP_ST and _isolated(fixed, i, reference):
                fixed[i] = np.nan
                continue
            fixed[i] = value
        history.append(float(value))
    return fixed


def _isolated(f0: np.ndarray, index: int, reference: float) -> bool:
    """後ろ 2 フレームが元の高さ（reference）に戻っていれば、飛んだのはこのフレームだけ。"""
    following = f0[index + 1 : index + 3]
    following = following[~np.isnan(following)]
    return len(following) > 0 and all(abs(12 * np.log2(v / reference)) <= ISOLATED_JUMP_ST for v in following)


def _first_dip(normalized: np.ndarray, min_lag: int, max_lag: int) -> int | None:
    """閾値を下回った最初の谷。無ければ最も深い谷が FALLBACK_THRESHOLD 未満のときだけ採り、他は無声。"""
    for lag in range(min_lag, max_lag):
        if normalized[lag] < THRESHOLD:
            while lag + 1 < max_lag and normalized[lag + 1] < normalized[lag]:
                lag += 1
            return lag
    deepest = min_lag + int(np.argmin(normalized[min_lag:max_lag]))
    return deepest if normalized[deepest] < FALLBACK_THRESHOLD else None


def _parabolic(values: np.ndarray, lag: int) -> float:
    if lag <= 0 or lag >= len(values) - 1:
        return float(lag)
    left, center, right = values[lag - 1], values[lag], values[lag + 1]
    denominator = left - 2 * center + right
    if denominator == 0:
        return float(lag)
    return lag + 0.5 * (left - right) / denominator


def loudness(samples: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """F0 を求めずに、`track` と同じ窓・間隔の (時刻, RMS) だけを返す。発話末の推定用。"""
    count = max(0, 1 + (len(samples) - FRAME_LENGTH) // HOP_LENGTH)
    if count == 0:
        return np.zeros(0), np.zeros(0)
    frames = np.lib.stride_tricks.sliding_window_view(samples, FRAME_LENGTH)[::HOP_LENGTH][:count]
    rms = np.sqrt(np.mean(frames**2, axis=1))
    times = (np.arange(count) * HOP_LENGTH + FRAME_LENGTH / 2) / SAMPLE_RATE
    return times, rms

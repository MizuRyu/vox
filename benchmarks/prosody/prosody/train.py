"""規則・L2 ロジスティック回帰・浅い勾配ブースティングを比べ、ロジスティック回帰の重みを書き出す。

評価は日付（録った日）で分けた交差検証の、学習に使っていない側の予測で行う。
「？」は誤って付けるのを重く見る（調査 E-2: 誤挿入 10 対 見逃し 1 なら閾値 0.909）。
"""

from __future__ import annotations

import json
import math
from datetime import date

import numpy as np
from scipy.stats import beta
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import GroupKFold, StratifiedKFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

from prosody import dataset, features, voxdata

THRESHOLDS = (0.5, 10 / 11)
MIN_ROWS = 20


def logistic():
    return make_pipeline(
        SimpleImputer(strategy="median", add_indicator=True, keep_empty_features=True),
        StandardScaler(),
        LogisticRegression(C=0.5, max_iter=1000),
    )


def boosting():
    return make_pipeline(
        SimpleImputer(strategy="median", add_indicator=True, keep_empty_features=True),
        GradientBoostingClassifier(max_depth=2, n_estimators=100, learning_rate=0.1),
    )


def rule_scores(table: list[dict]) -> np.ndarray:
    """調査 B-2 の規則。明瞭な上昇だけを「？」にする診断用の物差し。"""
    scores = []
    for r in table:
        ok = (
            r["voiced_ratio200"] >= 0.6
            and not math.isnan(r["last_voiced_gap_ms"])
            and r["last_voiced_gap_ms"] <= 60
            and not math.isnan(r["rise_st"])
            and r["rise_st"] >= 2.0
            and not math.isnan(r["slope150_st_per_s"])
            and r["slope150_st_per_s"] > 0
        )
        scores.append(1.0 if ok else 0.0)
    return np.array(scores)


def out_of_fold(make, x: np.ndarray, y: np.ndarray, groups: list[str]) -> tuple[np.ndarray, str]:
    distinct = sorted(set(groups))
    if len(distinct) >= 3:
        splitter, how = GroupKFold(n_splits=min(5, len(distinct))), f"日付で分けた {min(5, len(distinct))} 分割"
        splits = splitter.split(x, y, groups)
    else:
        folds = max(2, min(5, int(min(y.sum(), (~y).sum()))))
        splitter = StratifiedKFold(n_splits=folds, shuffle=True, random_state=0)
        how = f"日付が {len(distinct)} 日分しかないため層化 {folds} 分割（同じ日の発話が学習と評価に分かれる。楽観的）"
        splits = splitter.split(x, y)
    scores = np.full(len(y), np.nan)
    for train, test in splits:
        if len(set(y[train])) < 2:
            continue
        model = make().fit(x[train], y[train])
        scores[test] = model.predict_proba(x[test])[:, 1]
    return scores, how


def metrics(y: np.ndarray, scores: np.ndarray, threshold: float) -> dict:
    valid = ~np.isnan(scores)
    y, predicted = y[valid], scores[valid] >= threshold
    changed = int(predicted.sum())
    correct = int((predicted & y).sum())
    positives, negatives = int(y.sum()), int((~y).sum())
    return {
        "changed": changed,
        "precision": correct / changed if changed else None,
        # 片側 95% の下限（Clopper–Pearson）。0 件なら未定義。
        "precision_lower95": float(beta.ppf(0.05, correct, changed - correct + 1)) if changed and correct else None,
        "recall": correct / positives if positives else None,
        "false_insertions": changed - correct,
        "false_insertion_rate": (changed - correct) / negatives if negatives else None,
        "evaluated": int(valid.sum()),
    }


def percent(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.1f}%"


def evaluate(table: list[dict], target: str, lines: list[str]) -> None:
    columns_sets = {"音声のみ": features.ACOUSTIC, "音声＋文字の語尾": features.ACOUSTIC + features.TEXT}
    x_all, y, kept = dataset.matrix(table, features.ACOUSTIC + features.TEXT, target)
    lines.append(f"\n## {target}\n")
    if len(kept) < MIN_ROWS or len(set(y)) < 2:
        lines.append(f"ラベル付きの行が {len(kept)} 件（陽性 {int(y.sum())}）で、比べるには足りない（{MIN_ROWS} 件以上・両方のクラスが要る）。\n")
        return
    groups = [r["group"] for r in kept]
    lines.append(f"行 {len(kept)}（陽性 {int(y.sum())} / 陰性 {int((~y).sum())}）。出典: " + ", ".join(
        f"{s} {sum(r['source'] == s for r in kept)}" for s in ("contrast", "natural")) + "\n")
    lines.append("| モデル | 特徴 | 閾値 | 変更 | 適合率 | 下限95% | 再現率 | 誤挿入 | 誤挿入率 |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    how = ""
    kana = np.array([r["ending_kana"] == 1.0 for r in kept])
    kana_lines = []
    if target == "want_question":
        m = metrics(y, rule_scores(kept), 0.5)
        lines.append(_row("規則（上昇 2 半音）", "音声のみ", "—", m))
    for name, columns in columns_sets.items():
        index = [(features.ACOUSTIC + features.TEXT).index(c) for c in columns]
        x = x_all[:, index]
        for model_name, make in (("ロジスティック回帰", logistic), ("勾配ブースティング", boosting)):
            scores, how = out_of_fold(make, x, y, groups)
            for threshold in THRESHOLDS:
                lines.append(_row(model_name, name, f"{threshold:.3f}", metrics(y, scores, threshold)))
            if kana.sum() >= 5 and name == "音声＋文字の語尾" and model_name == "ロジスティック回帰":
                kana_lines.append(_row(model_name, "「かな」だけ", "0.500", metrics(y[kana], scores[kana], 0.5)))
    lines.append(f"\n評価の分け方: {how}\n")
    if kana_lines:
        lines += ["「かな」で終わる文だけ:\n", "| モデル | 対象 | 閾値 | 変更 | 適合率 | 下限95% | 再現率 | 誤挿入 | 誤挿入率 |", "|---|---|---|---|---|---|---|---|---|", *kana_lines, ""]
    if target == "want_question":
        export(x_all, y)


def _row(model: str, columns: str, threshold: str, m: dict) -> str:
    return (
        f"| {model} | {columns} | {threshold} | {m['changed']}/{m['evaluated']} | {percent(m['precision'])} | "
        f"{percent(m['precision_lower95'])} | {percent(m['recall'])} | {m['false_insertions']} | {percent(m['false_insertion_rate'])} |"
    )


def export(x: np.ndarray, y: np.ndarray) -> None:
    """全件で学習したロジスティック回帰を、Swift で同じ計算ができる形で書き出す。"""
    model = logistic().fit(x, y)
    imputer, scaler, head = model.named_steps.values()
    payload = {
        "trained_on": date.today().isoformat(),
        "rows": int(len(y)),
        "features": features.ACOUSTIC + features.TEXT,
        "impute_median": [None if math.isnan(v) else float(v) for v in imputer.statistics_],
        "indicator_features": [int(i) for i in imputer.indicator_.features_] if imputer.indicator_ else [],
        "scale_mean": scaler.mean_.tolist(),
        "scale_std": scaler.scale_.tolist(),
        "weights": head.coef_[0].tolist(),
        "bias": float(head.intercept_[0]),
        "threshold": 10 / 11,
        "note": "入力 = [補完した特徴..., 欠損フラグ...] を標準化 → 内積 + bias → sigmoid。yin.py と同じ設定で特徴を作ること",
    }
    (voxdata.DATA / "model.json").write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")


def main() -> None:
    voxdata.DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    table = dataset.rows()
    lines = [f"# vox-prosody 評価（{date.today().isoformat()}）\n", f"文末の行 {len(table)} 件（ラベル無しを含む）。"]
    for target in ("want_question", "want_ellipsis"):
        evaluate(table, target, lines)
    report = "\n".join(lines) + "\n"
    (voxdata.DATA / "report.md").write_text(report, encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()

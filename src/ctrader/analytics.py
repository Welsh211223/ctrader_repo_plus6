from __future__ import annotations

import json
import math
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd


def append_trades(pool: str, plan: pd.DataFrame, data_base: Path) -> None:
    fp = data_base / f"trades_{pool}.csv"
    plan = plan.copy()
    plan["ts"] = datetime.now(timezone.utc).isoformat()
    if fp.exists():
        old = pd.read_csv(fp)
        pd.concat([old, plan], ignore_index=True).to_csv(fp, index=False)
    else:
        plan.to_csv(fp, index=False)


def update_equity_and_pnl(
    pool: str, holdings: dict[str, float], prices: dict[str, float], data_base: Path
) -> None:
    equity = sum(
        float(holdings.get(t, 0.0)) * float(prices.get(t, 0.0)) for t in holdings
    )
    fp = data_base / f"equity_{pool}.csv"
    row = {"ts": datetime.now(timezone.utc).isoformat(), "equity": equity}
    if fp.exists():
        df = pd.read_csv(fp)
        df = pd.concat([df, pd.DataFrame([row])], ignore_index=True)
        df.to_csv(fp, index=False)
    else:
        pd.DataFrame([row]).to_csv(fp, index=False)


def equity_stats(equity_series: pd.Series) -> dict:
    if equity_series.empty or equity_series.max() <= 0:
        return {"max_drawdown": 0.0, "vol_daily": 0.0, "sharpe_daily": 0.0}
    eq = equity_series.astype(float).values
    peaks = eq.cummax()
    dd = (eq / peaks) - 1.0
    max_dd = float(dd.min())
    rets = []
    for i in range(1, len(eq)):
        if eq[i - 1] > 0:
            rets.append(eq[i] / eq[i - 1] - 1.0)
    if len(rets) < 2:
        vol = 0.0
        sharpe = 0.0
    else:
        mu = sum(rets) / len(rets)
        var = sum((r - mu) ** 2 for r in rets) / (len(rets) - 1)
        vol = var**0.5
        sharpe = mu / vol if vol > 0 else 0.0
    return {
        "max_drawdown": max_dd,
        "vol_daily": float(vol),
        "sharpe_daily": float(sharpe),
    }


def bucket_weights(
    weights: dict[str, float], categories: dict[str, str]
) -> dict[str, float]:
    out = {"core": 0.0, "ai": 0.0, "meme": 0.0, "other": 0.0}
    for t, w in (weights or {}).items():
        b = categories.get(t, "other")
        out[b] = out.get(b, 0.0) + float(w)
    return out


def risk_report(pool: str, categories: dict[str, str], base_dir: Path) -> Path:
    eq_fp = base_dir / f"equity_{pool}.csv"
    rs_dir = base_dir / "run_summaries"
    eq_stats = {}
    if eq_fp.exists():
        df = pd.read_csv(eq_fp)
    else:
        df = None
    if df is not None and not df.empty:
        eq_stats = equity_stats(df["equity"])
    latest = None
    if rs_dir.exists():
        runs = sorted(rs_dir.glob(f"run_{pool}_*_trades.csv"))
        if runs:
            import pandas as pd

            latest = pd.read_csv(runs[-1])
    if latest is not None and not latest.empty:
        alloc = latest.groupby("ticker")["est_value"].sum().reset_index()
        total = alloc["est_value"].sum()
        if total > 0:
            alloc["weight"] = alloc["est_value"] / total
            bw = bucket_weights(dict(zip(alloc["ticker"], alloc["weight"])), categories)
        else:
            bw = {"core": 0.0, "ai": 0.0, "meme": 0.0, "other": 0.0}
    else:
        bw = {"core": 0.0, "ai": 0.0, "meme": 0.0, "other": 0.0}
    out = {
        "pool": pool,
        "max_drawdown": eq_stats.get("max_drawdown", 0.0),
        "vol_daily": eq_stats.get("vol_daily", 0.0),
        "sharpe_daily": eq_stats.get("sharpe_daily", 0.0),
        "bucket_core": bw.get("core", 0.0),
        "bucket_ai": bw.get("ai", 0.0),
        "bucket_meme": bw.get("meme", 0.0),
        "bucket_other": bw.get("other", 0.0),
    }
    out_fp = base_dir / f"risk_report_{pool}.csv"
    import pandas as pd

    pd.DataFrame([out]).to_csv(out_fp, index=False)
    return out_fp

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import streamlit as st
from dotenv import load_dotenv

from ctrader.analytics import risk_report
from ctrader.data_providers.coinspot_v2 import CoinSpotV2

# --- make sure "src" is on sys.path so `ctrader` imports work anywhere ---

HERE = Path(__file__).resolve()
SRC_DIR = HERE.parents[1]  # ...\src
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))
# ------------------------------------------------------------------------


load_dotenv()


st.set_page_config(
    page_title="Crypto Trader Dashboard",
    layout="wide",
    initial_sidebar_state="expanded",
)
st.title("Crypto Trader Dashboard")

BASE = HERE.parents[2] / "data"  # project_root\data
pool = st.selectbox("Pool", ["conservative", "aggressive"])

# ------------------- Run status (from runs.jsonl) -------------------
st.subheader("Run status")
runlog_fp = BASE / "logs" / "runs.jsonl"
latest = None
if runlog_fp.exists():
    try:
        with open(runlog_fp, "r", encoding="utf-8") as f:
            raw_lines = [line.strip() for line in f if line.strip()]
            recs = [json.loads(x) for x in raw_lines[-500:]]  # tail only
        df_runs = pd.DataFrame(recs)
        if not df_runs.empty and "pool" in df_runs.columns:
            latest = df_runs[df_runs["pool"] == pool].tail(1)
    except Exception:
        latest = None

cols = st.columns(5)
if latest is not None and len(latest) == 1:
    r = latest.iloc[0]
    cols[0].metric("Last run (UTC)", str(r.get("ts", "")))
    cols[1].metric("Risk-off", str(r.get("risk_off", False)))
    cols[2].metric("Reserve %", f"{float(r.get('reserve_pct', 0.0)):.1f}%")
    cols[3].metric("Cap %", f"{float(r.get('cap_pct', 0.0)):.1f}%")
    cols[4].metric("Trades", int(r.get("trades_selected", 0)))
    st.caption(
        f"Cap mode: {r.get('cap_mode','')}, priority: {r.get('cap_priority','')}, reasons: {', '.join(r.get('cap_reasons', [])) or 'none'}"
    )
else:
    st.info("No run log yet. Run the trader to populate `data\\logs\\runs.jsonl`.")

# ------------------- Equity -------------------
st.subheader("Equity")
eq_fp = BASE / f"equity_{pool}.csv"
if eq_fp.exists():
    df_eq = pd.read_csv(eq_fp)
    if not df_eq.empty and {"ts", "equity"} <= set(df_eq.columns):
        st.line_chart(df_eq.set_index("ts")["equity"])
    else:
        st.info("Equity file is empty.")
else:
    st.info("No equity yet. Run a trade pass to generate it.")

# ------------------- Drawdown -------------------
st.subheader("Drawdown")
if eq_fp.exists():
    df_eq = pd.read_csv(eq_fp)
    if not df_eq.empty and {"ts", "equity"} <= set(df_eq.columns):
        eq = df_eq["equity"].astype(float).to_numpy()
        peaks = np.maximum.accumulate(eq)
        dd = (eq / np.where(peaks == 0, np.nan, peaks)) - 1.0
        st.line_chart(
            pd.DataFrame({"ts": df_eq["ts"], "drawdown": dd}).set_index("ts")[
                "drawdown"
            ]
        )

# ------------------- Trades -------------------
st.subheader("Trades (last 200)")
tr_fp = BASE / f"trades_{pool}.csv"
if tr_fp.exists():
    try:
        df_tr = pd.read_csv(tr_fp)
        st.dataframe(df_tr.tail(200))
    except Exception as e:
        st.warning(f"Could not read trades: {e}")
else:
    st.info("No trades yet.")

# ------------------- Allocation from last run -------------------
st.subheader("Allocation (latest run est_value)")
try:
    rs = sorted((BASE / "run_summaries").glob(f"run_{pool}_*_trades.csv"))
    if rs:
        last = pd.read_csv(rs[-1])
        if not last.empty and {"ticker", "est_value"} <= set(last.columns):
            alloc = last.groupby("ticker", as_index=False)["est_value"].sum()
            total = alloc["est_value"].sum()
            if total > 0:
                alloc["weight_pct"] = (alloc["est_value"] / total) * 100.0
                st.dataframe(alloc.sort_values("weight_pct", ascending=False))
            else:
                st.caption("Latest run has zero notional.")
    else:
        st.caption("No run summaries yet.")
except Exception as e:
    st.warning(f"Allocation error: {e}")

# ------------------- Balances (Read-Only) -------------------
st.subheader("Balances (Read-Only)")
ak = os.getenv("COINSPOT_API_KEY", "").strip()
sk = os.getenv("COINSPOT_API_SECRET", "").strip()
if ak and sk:
    try:
        cs = CoinSpotV2(ak, sk)
        ro = cs.ro_balances()
        bals = (ro or {}).get("balances", {})
        if isinstance(bals, dict) and bals:
            rows = cast(
                list[dict[str, Any]],
                [{"coin": k.upper(), "balance": v} for k, v in bals.items()],
            )
            st.dataframe(pd.DataFrame(rows).sort_values("coin"))
        else:
            st.info("No balances returned (check RO access for your API key).")
    except Exception as e:
        st.warning(f"RO balances error: {e}")
else:
    st.caption(
        "Set COINSPOT_API_KEY / COINSPOT_API_SECRET in your .env to show balances."
    )

# ------------------- Risk report -------------------
st.subheader("Risk Report")
try:
    cats = {
        "BTC": "core",
        "ETH": "core",
        "SOL": "core",
        "AVAX": "core",
        "XRP": "core",
        "HBAR": "ai",
        "QNT": "ai",
        "DOGE": "meme",
        "SHIB": "meme",
    }
    rr_fp = risk_report(pool, cats, BASE)
    st.dataframe(pd.read_csv(rr_fp))
except Exception as e:
    st.caption(f"Risk report unavailable: {e}")

# ------------------- Signals (last run) -------------------
st.subheader("Signals (last run)")
sig_dir = BASE / "signals"
if sig_dir.exists():
    files = sorted(sig_dir.glob(f"signals_{pool}_*.csv"))
    if files:
        last_sig = files[-1]
        try:
            sdf = pd.read_csv(last_sig)
            st.dataframe(sdf)
            if all(c in sdf.columns for c in ("price_usd", "sma200")) and len(sdf) > 0:
                breadth = (
                    float((sdf["price_usd"] > sdf["sma200"]).sum())
                    * 100.0
                    / max(1, len(sdf))
                )
                st.metric("Breadth (% above SMA200)", f"{breadth:.1f}%")
        except Exception as e:
            st.warning(f"Could not read signals: {e}")
    else:
        st.info("No signals yet")
else:
    st.info("No signals directory yet.")

from __future__ import annotations
import argparse, os
from ctrader.data_providers.coinspot import _get as _pub_get  # type: ignore
from ctrader.data_providers.coinspot_v2 import CoinSpotV2

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", choices=["pub","ro","full"], default="pub")
    args = ap.parse_args()
    try:
        if args.check == "pub":
            d = _pub_get("/latest"); print("Public OK:", bool(d))
        else:
            ak=os.getenv("COINSPOT_API_KEY","").strip(); sk=os.getenv("COINSPOT_API_SECRET","").strip()
            cs = CoinSpotV2(ak, sk); s = cs.ro_status() if args.check=="ro" else cs.status()
            print(f"{args.check.upper()} OK:", s.get("status","<no status>"))
    except Exception as e:
        print("ERROR:", e); raise SystemExit(1)

if __name__ == "__main__":
    main()

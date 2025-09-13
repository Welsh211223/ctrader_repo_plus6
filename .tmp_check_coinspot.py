import importlib
import json
import os
import sys


def try_it(mod_name, cls_name, method):
    try:
        mod = importlib.import_module(mod_name)
        cls = getattr(mod, cls_name)
        key = os.getenv("COINSPOT_API_KEY", "")
        sec = os.getenv("COINSPOT_API_SECRET", "")
        if not key or not sec:
            print("ENV_NOT_SET")
            return False
        client = cls(key, sec)
        fn = getattr(client, method, None)
        if not fn:
            return False
        res = fn()
        print("OK", json.dumps(res)[:200])
        return True
    except Exception as e:
        print(f"{mod_name}.{cls_name} -> {e}")
        return False


ok = try_it(
    "ctrader.data_providers.coinspot_v2", "CoinSpotV2", "ro_balances"
) or try_it("ctrader.data_providers.coinspot", "CoinSpot", "balances")
sys.exit(0 if ok else 2)

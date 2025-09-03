from __future__ import annotations
from pathlib import Path
import json, time, hashlib

class JsonDiskCache:
    def __init__(self, base: Path, ttl_sec: int = 86400):
        self.base = Path(base); self.base.mkdir(parents=True, exist_ok=True)
        self.ttl_sec = int(ttl_sec)

    def _path_for(self, key: str) -> Path:
        h = hashlib.sha256(key.encode("utf-8")).hexdigest()
        return self.base / f"{h}.json"

    def get(self, key: str):
        fp = self._path_for(key)
        if not fp.exists(): return None
        try:
            with open(fp, "r", encoding="utf-8") as f: payload = json.load(f)
            ts = float(payload.get("_ts", 0))
            if time.time() - ts > self.ttl_sec: return None
            return payload.get("data")
        except Exception:
            return None

    def set(self, key: str, data):
        fp = self._path_for(key)
        with open(fp, "w", encoding="utf-8") as f:
            json.dump({"_ts": time.time(), "data": data}, f)

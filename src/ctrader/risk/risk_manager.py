from __future__ import annotations

from dataclasses import dataclass


@dataclass
class RiskRules:
    max_per_asset_pct: float = 100.0
    max_meme_bucket_pct: float = 100.0
    max_ai_bucket_pct: float = 100.0
    per_asset_caps: dict[str, float] | None = None


def enforce_caps(
    weights: dict[str, float], categories: dict[str, str], rules: RiskRules
) -> dict[str, float]:
    w = dict(weights)
    caps = rules.per_asset_caps or {}
    for t, cap_pct in caps.items():
        if t in w:
            w[t] = min(float(w[t]), float(cap_pct) / 100.0)
    if rules.max_per_asset_pct < 100:
        maxw = rules.max_per_asset_pct / 100.0
        for t in list(w.keys()):
            w[t] = min(float(w[t]), maxw)

    def cap_bucket(bucket: str, cap_pct: float):
        cap = cap_pct / 100.0
        members = [t for t, c in categories.items() if c == bucket and t in w]
        total = sum(w[t] for t in members)
        if total > cap and total > 0:
            scale = cap / total
            for t in members:
                w[t] *= scale

    cap_bucket("meme", rules.max_meme_bucket_pct)
    cap_bucket("ai", rules.max_ai_bucket_pct)
    s = sum(max(0.0, v) for v in w.values())
    return {k: v / s for k, v in w.items()} if s > 0 else w

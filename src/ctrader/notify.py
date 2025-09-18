from __future__ import annotations

import json
from pathlib import Path

import requests


def post_discord_embed(
    webhook_url: str,
    title: str,
    description: str,
    color: int = 3066993,
    fields: dict[str, str] | None = None,
) -> None:
    if not webhook_url:
        return
    payload = {
        "embeds": [
            {
                "title": title,
                "description": description,
                "color": color,
                "fields": [
                    {"name": k, "value": str(v)} for k, v in (fields or {}).items()
                ],
            }
        ]
    }
    try:
        requests.post(webhook_url, json=payload, timeout=10)
    except Exception:
        pass


def append_jsonl(log_path: Path, record: dict) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")

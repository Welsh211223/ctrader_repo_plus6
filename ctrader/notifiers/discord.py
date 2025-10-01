from __future__ import annotations

import os

import requests


def notify(message: str) -> None:
    url = os.getenv("DISCORD_WEBHOOK_URL")
    if not url:
        print("[discord] " + message)
        return
    try:
        requests.post(url, json={"content": message}, timeout=5)
    except Exception as e:
        print(f"[discord] error: {e}")

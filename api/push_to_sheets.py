import argparse
import csv
import os
import re
import sys

import gspread
from google.oauth2.service_account import Credentials
from gspread.exceptions import WorksheetNotFound

SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]


def get_client(sa_path: str):
    path = sa_path or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path or not os.path.exists(path):
        sys.exit(
            "Service account JSON not found. Pass --sa or set GOOGLE_APPLICATION_CREDENTIALS."
        )
    creds = Credentials.from_service_account_file(path, scopes=SCOPES)
    return gspread.authorize(creds)


def open_sheet(gc, sheet_id: str):
    sid = sheet_id or os.environ.get("SHEET_ID")
    if not sid:
        sys.exit("No spreadsheet specified. Set SHEET_ID or pass --sheet-id.")
    if re.fullmatch(r"[A-Za-z0-9_-]{20,}", sid):
        return gc.open_by_key(sid)
    sys.exit("Pass a spreadsheet ID (not title).")


def ensure_worksheet(sh, title: str):
    tab = title or os.environ.get("TAB") or "Sheet1"
    try:
        return sh.worksheet(tab)
    except WorksheetNotFound:
        return sh.add_worksheet(title=tab, rows=2000, cols=26)


def main():
    ap = argparse.ArgumentParser(
        description="Append a CSV into a Google Sheet (no Drive API)."
    )
    ap.add_argument("--csv", required=True)
    ap.add_argument("--sheet-id")
    ap.add_argument("--tab")
    ap.add_argument("--sa")
    args = ap.parse_args()

    if not os.path.exists(args.csv):
        sys.exit(f"CSV not found: {args.csv}")

    gc = get_client(args.sa)
    sh = open_sheet(gc, args.sheet_id)
    ws = ensure_worksheet(sh, args.tab)

    with open(args.csv, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    if not rows:
        print("CSV empty; nothing to append.")
        return

    ws.append_rows(rows, value_input_option="USER_ENTERED")
    print(f"Appended {len(rows)} rows -> {sh.title} / {ws.title}")


if __name__ == "__main__":
    main()

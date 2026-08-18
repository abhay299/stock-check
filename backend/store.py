"""
Tiny SQLite store for the user's saved watchlist.

Single-user, so no accounts — just one table of tickers. Kept deliberately simple
(stdlib sqlite3, a fresh connection per call); fine for the low request volume here.
The DB file lives next to this module and is git-ignored (it's personal data).
"""
import sqlite3
from pathlib import Path

_DB_PATH = Path(__file__).resolve().parent / "watchlist.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS watchlist (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    ticker   TEXT UNIQUE NOT NULL,
    added_at TEXT DEFAULT CURRENT_TIMESTAMP
)
"""


def _run(query, params=(), fetch=False):
    conn = sqlite3.connect(_DB_PATH)
    try:
        conn.execute(_SCHEMA)  # idempotent; ensures the table exists
        cur = conn.execute(query, params)
        rows = cur.fetchall() if fetch else None
        conn.commit()
        return rows
    finally:
        conn.close()


def list_tickers():
    """Saved tickers, oldest-added first."""
    return [r[0] for r in _run("SELECT ticker FROM watchlist ORDER BY id", fetch=True)]


def add_ticker(ticker):
    # INSERT OR IGNORE so re-adding an existing ticker is a harmless no-op.
    _run("INSERT OR IGNORE INTO watchlist (ticker) VALUES (?)", (ticker,))
    return list_tickers()


def remove_ticker(ticker):
    _run("DELETE FROM watchlist WHERE ticker = ?", (ticker,))
    return list_tickers()

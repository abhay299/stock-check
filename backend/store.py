"""
Store for the user's saved watchlist.

Single-user, so no accounts — just one table of tickers. Uses Postgres when a
DATABASE_URL is set (e.g. on Render, whose free disk is ephemeral and would lose a
SQLite file on every restart), and falls back to a local SQLite file for development.
The two backends differ only in the driver and the SQL placeholder/upsert syntax, so
the query-running logic below is shared.
"""
import os

_DATABASE_URL = os.environ.get("DATABASE_URL", "").strip()

if _DATABASE_URL:
    import psycopg  # psycopg 3

    # Render hands out the legacy "postgres://" scheme; psycopg wants "postgresql://".
    _PG_URL = _DATABASE_URL.replace("postgres://", "postgresql://", 1)

    _CREATE = (
        "CREATE TABLE IF NOT EXISTS watchlist ("
        "id SERIAL PRIMARY KEY, "
        "ticker TEXT UNIQUE NOT NULL, "
        "added_at TIMESTAMPTZ DEFAULT now())"
    )
    _INSERT = "INSERT INTO watchlist (ticker) VALUES (%s) ON CONFLICT (ticker) DO NOTHING"
    _DELETE = "DELETE FROM watchlist WHERE ticker = %s"

    def _connect():
        return psycopg.connect(_PG_URL)

else:
    import sqlite3
    from pathlib import Path

    _DB_PATH = Path(__file__).resolve().parent / "watchlist.db"

    _CREATE = (
        "CREATE TABLE IF NOT EXISTS watchlist ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, "
        "ticker TEXT UNIQUE NOT NULL, "
        "added_at TEXT DEFAULT CURRENT_TIMESTAMP)"
    )
    _INSERT = "INSERT OR IGNORE INTO watchlist (ticker) VALUES (?)"
    _DELETE = "DELETE FROM watchlist WHERE ticker = ?"

    def _connect():
        return sqlite3.connect(_DB_PATH)


_SELECT = "SELECT ticker FROM watchlist ORDER BY id"


def _run(query, params=None, fetch=False):
    conn = _connect()
    try:
        conn.execute(_CREATE)  # idempotent; ensures the table exists
        cur = conn.execute(query, params) if params else conn.execute(query)
        rows = cur.fetchall() if fetch else None
        conn.commit()
        return rows
    finally:
        conn.close()


def list_tickers():
    """Saved tickers, oldest-added first."""
    return [r[0] for r in _run(_SELECT, fetch=True)]


def add_ticker(ticker):
    # Re-adding an existing ticker is a harmless no-op (IGNORE / ON CONFLICT).
    _run(_INSERT, (ticker,))
    return list_tickers()


def remove_ticker(ticker):
    _run(_DELETE, (ticker,))
    return list_tickers()

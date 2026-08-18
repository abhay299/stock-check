#!/usr/bin/env python3
"""
FastAPI backend for the stock pre-screen.

Wraps screener.evaluate() so the Flutter app (web + Android) can request finished
scorecards over HTTP instead of anyone re-implementing the logic client-side.

Run (dev):   uvicorn app:app --reload --port 8000
Then open:   http://127.0.0.1:8000/docs   (interactive API explorer)
"""
import datetime
import time
from typing import Optional

from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware

from screener import CHECKS, HERE, evaluate, read_watchlist

app = FastAPI(title="Stock Pre-Screen API", version="0.1.0")

# Flutter web is served from a different origin, so it must be allowed to call us.
# Wide-open is fine for a single-user dev app; tighten to your own domain if deployed.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- tiny in-memory cache: fundamentals barely move, so don't re-hit Yahoo per request.
# (Phase 3 swaps this for SQLite + a scheduled refresh.)
_CACHE = {}                 # ticker -> (fetched_at, result)
_TTL_SECONDS = 6 * 3600


def _cached_evaluate(ticker):
    now = time.time()
    hit = _CACHE.get(ticker)
    if hit and now - hit[0] < _TTL_SECONDS:
        return hit[1]
    result = evaluate(ticker)
    _CACHE[ticker] = (now, result)
    return result


def _to_api(r):
    """Shape an evaluate() result into clean JSON for the app (ordered check list)."""
    return {
        "ticker": r["ticker"],
        "name": r["name"],
        "sector": r["sector"],
        "currency": r["currency"],
        "bucket": r["bucket"],          # eligible | near-miss | rejected | insufficient
        "fails": r["fails"],
        "applicable": r["applicable"],
        "checks": [
            {
                "key": k,
                "label": label,
                "section": section,
                "value": r["metrics"][k]["value"],      # raw number or null
                "verdict": r["metrics"][k]["verdict"],   # pass | fail | na
                "note": r["metrics"][k]["note"],
            }
            for k, label, section in CHECKS
        ],
    }


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/stock/{ticker}")
def stock(ticker: str):
    """Full scorecard for a single ticker."""
    return _to_api(_cached_evaluate(ticker.upper()))


@app.get("/screen")
def screen(
    tickers: Optional[str] = Query(
        default=None,
        description="Comma-separated tickers (e.g. AAPL,TCS.NS). Omit to use watchlist.txt.",
    )
):
    """Screen a list of tickers (or the default watchlist) and return all scorecards."""
    if tickers:
        symbols = [t.strip().upper() for t in tickers.split(",") if t.strip()]
    else:
        symbols = read_watchlist(HERE / "watchlist.txt")
    results = [_to_api(_cached_evaluate(s)) for s in symbols]
    return {
        "as_of": datetime.date.today().isoformat(),
        "count": len(results),
        "results": results,
    }

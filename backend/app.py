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

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

import yfinance as yf

import store
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


# --- Symbol search (look up by company name, not just an exact ticker) --------

def _yahoo_search(q):
    """yfinance's Search signature has drifted across versions, so try a few kwarg
    shapes (skipping news where supported) and degrade to an empty list on error."""
    for kwargs in ({"max_results": 20, "news_count": 0}, {"news_count": 0}, {}):
        try:
            return yf.Search(q, **kwargs).quotes or []
        except TypeError:
            continue  # this kwarg shape isn't supported here; try the next
        except Exception:
            return []
    return []


def _to_result(x):
    return {
        "ticker": x.get("symbol"),
        "name": x.get("shortname") or x.get("longname") or x.get("symbol"),
        "exchange": x.get("exchDisp") or "",
        "type": x.get("quoteType") or "",
    }


# Exchanges floated to the top of results — the markets this user actually screens.
_PREFERRED_EXCHANGES = {
    "NSE", "Bombay", "BSE", "NASDAQ", "NasdaqGS", "NasdaqGM", "NasdaqCM", "NYSE", "NYSEArca",
}


@app.get("/search")
def search_symbols(
    q: str = Query(..., min_length=1, description="Company name or ticker fragment")
):
    """Look up matching stocks by name or symbol; US + India listings first.

    Yahoo's fuzzy search often omits the exact NSE/BSE listing when the user types a
    bare symbol-like word (e.g. "reliance" misses RELIANCE.NS). So when the query looks
    like a single symbol we also resolve <Q>.NS / <Q>.BO directly and prepend them — a
    supplementary Search on an exact symbol is fast whether it hits or comes back empty.
    """
    q = q.strip()
    quotes = list(_yahoo_search(q))

    token = q.upper()
    symbol_like = " " not in q and 1 <= len(token) <= 12 and token.replace(".", "").isalnum()
    if symbol_like:
        # Resolve exact listings and prepend them, NSE before BSE (the primary market here).
        direct = []
        for suffix in (".NS", ".BO"):
            if not token.endswith(suffix):
                direct += _yahoo_search(token + suffix)
        quotes = direct + quotes

    seen, results = set(), []
    for x in quotes:
        if x.get("quoteType") not in ("EQUITY", "ETF"):
            continue  # skip options, indices, currencies, etc.
        sym = x.get("symbol")
        if not sym or sym in seen:
            continue
        seen.add(sym)
        results.append(_to_result(x))

    # Stable sort: preferred exchanges first, existing order (direct hits) kept within.
    results.sort(key=lambda r: 0 if r["exchange"] in _PREFERRED_EXCHANGES else 1)
    return {"query": q, "results": results[:12]}


# --- Saved watchlist (backend-stored so it's the same on web + phone) ---------

@app.get("/watchlist/tickers")
def watchlist_tickers():
    """Just the saved tickers — fast; the app uses it to know what's already added."""
    return {"tickers": store.list_tickers()}


@app.get("/watchlist")
def watchlist():
    """Full scorecards for every stock the user has saved."""
    tickers = store.list_tickers()
    results = [_to_api(_cached_evaluate(t)) for t in tickers]
    return {
        "as_of": datetime.date.today().isoformat(),
        "count": len(results),
        "results": results,
    }


@app.post("/watchlist/{ticker}")
def watchlist_add(ticker: str):
    """Add a ticker to the saved watchlist; returns the updated list."""
    t = ticker.strip().upper()
    if not t:
        raise HTTPException(status_code=400, detail="Empty ticker")
    return {"tickers": store.add_ticker(t), "added": t}


@app.delete("/watchlist/{ticker}")
def watchlist_remove(ticker: str):
    """Remove a ticker from the saved watchlist; returns the updated list."""
    t = ticker.strip().upper()
    return {"tickers": store.remove_ticker(t), "removed": t}

#!/usr/bin/env python3
"""
Stock pre-screen  ·  §1 Quality + §2 Growth
===========================================

A FIRST-PASS FILTER. It reads watchlist.txt, pulls fundamentals from Yahoo Finance
(free, works for US + India tickers), and sorts each stock into:

    ELIGIBLE     passes every applicable check
    NEAR-MISS    fails exactly one check
    REJECTED     fails two or more
    INSUFFICIENT not enough data to judge

It only checks the quantitative basics so you know which stocks are worth digging
into. Valuation (§3), moat/management (§4) and momentum (§5) are left for you to
check by hand in a proper app.

Usage:   python screener.py [path/to/watchlist.txt]
"""

import csv
import datetime
import logging
import sys
import time
import warnings
from pathlib import Path

warnings.simplefilter("ignore")  # set before yfinance/urllib3 import to mute their warnings

try:
    import yfinance as yf
except ImportError:
    sys.exit("Missing dependencies. Run:  pip install -r requirements.txt")

logging.getLogger("yfinance").setLevel(logging.CRITICAL)

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import config  # noqa: E402

PASS, FAIL, NA = "pass", "fail", "na"

# key, column header, checklist section
CHECKS = [
    ("roce",     "ROCE",   "§1"),
    ("roe",      "ROE",    "§1"),
    ("de",       "D/E",    "§1"),
    ("ocf",      "OCF",    "§1"),
    ("sales_g",  "SALES",  "§2"),
    ("profit_g", "PROFIT", "§2"),
    ("eps_g",    "EPS",    "§2"),
]
LABELS = {"roce": "ROCE", "roe": "ROE", "de": "Debt/Eq", "ocf": "OpCashFlow",
          "sales_g": "Sales", "profit_g": "Profit", "eps_g": "EPS"}


# --------------------------------------------------------------------------- #
# yfinance helpers — statement DataFrames have line items as rows and one
# column per fiscal year. Field names drift between versions, so we look up a
# row by trying a list of candidate labels.
# --------------------------------------------------------------------------- #
def _row(df, names):
    """Return a line item as a Series across years (newest first), or None."""
    if df is None or getattr(df, "empty", True):
        return None
    lut = {str(i).lower(): i for i in df.index}
    for n in names:
        hit = lut.get(n.lower())
        if hit is not None:
            s = df.loc[hit].dropna()
            if not s.empty:
                try:
                    s = s.sort_index(ascending=False)  # newest year first
                except Exception:
                    pass
                return s
    return None


def _latest(df, names):
    s = _row(df, names)
    return None if s is None else float(s.iloc[0])


def _cagr(series, max_years):
    """CAGR from oldest->newest over the available span (capped at max_years).
    Returns (rate, years_used). rate is None when it can't be computed (a sign
    change or a non-positive endpoint makes CAGR meaningless)."""
    if series is None or len(series) < 2:
        return None, None
    vals = [float(v) for v in series.values][: max_years + 1]  # newest first
    end, begin = vals[0], vals[-1]
    years = len(vals) - 1
    if begin <= 0 or end <= 0 or years < 1:
        return None, years
    return (end / begin) ** (1.0 / years) - 1.0, years


def evaluate(ticker):
    t = yf.Ticker(ticker)
    try:
        info = t.info or {}
    except Exception:
        info = {}
    inc = _safe(lambda: t.income_stmt)
    bal = _safe(lambda: t.balance_sheet)
    cf = _safe(lambda: t.cashflow)

    name = info.get("shortName") or info.get("longName") or ""
    if not name:
        # .info is frequently rate-limited from cloud IPs (works locally, blocked on
        # Render), so fall back to Search, which returns the company name reliably.
        try:
            for q in yf.Search(ticker).quotes:
                if str(q.get("symbol", "")).upper() == ticker.upper():
                    name = q.get("shortname") or q.get("longname") or ""
                    break
        except Exception:
            pass
    name = name or ticker
    sector = info.get("sector") or ""
    industry = info.get("industry") or ""
    is_fin = sector in config.FINANCIAL_SECTORS or "Bank" in industry or "Insurance" in industry
    currency = info.get("financialCurrency") or info.get("currency") or ""
    if not currency and ticker.upper().endswith((".NS", ".BO")):
        currency = "INR"

    th = config.THRESHOLDS
    m = {}

    def put(key, value, ok, na=False, note=""):
        verdict = NA if (na or value is None) else (PASS if ok else FAIL)
        m[key] = {"value": value, "verdict": verdict, "note": note}

    # -- §1 Excellent business --------------------------------------------- #
    net_income = _latest(inc, ["Net Income", "Net Income Common Stockholders"])
    equity = _latest(bal, ["Stockholders Equity", "Total Stockholder Equity",
                           "Common Stock Equity"])

    roe = (net_income / equity) if (net_income is not None and equity and equity > 0) \
        else info.get("returnOnEquity")
    put("roe", roe, roe is not None and roe >= th["roe_min"])

    ebit = _latest(inc, ["EBIT", "Operating Income", "Operating Income Or Loss"])
    total_assets = _latest(bal, ["Total Assets"])
    curr_liab = _latest(bal, ["Current Liabilities", "Total Current Liabilities"])
    # Banks/financials don't report a current-liabilities split, so a missing value is a
    # reliable structural signal of a financial even when .info's sector is unavailable
    # (e.g. from Render). ROCE and Debt/Equity are meaningless for financials → N/A.
    financial = is_fin or curr_liab is None
    roce = None
    if None not in (ebit, total_assets, curr_liab) and (total_assets - curr_liab) > 0:
        roce = ebit / (total_assets - curr_liab)
    put("roce", roce, roce is not None and roce >= th["roce_min"],
        na=financial, note="n/a (financial)" if financial else "")

    total_debt = _latest(bal, ["Total Debt"])
    de = None
    if total_debt is not None and equity and equity > 0:
        de = total_debt / equity
    elif info.get("debtToEquity") is not None:
        de = info["debtToEquity"] / 100.0  # Yahoo reports this as a percentage
    put("de", de, de is not None and de <= th["debt_to_equity_max"],
        na=financial, note="n/a (financial)" if financial else "")

    ocf = _latest(cf, ["Operating Cash Flow", "Total Cash From Operating Activities",
                       "Cash Flow From Continuing Operating Activities"])
    if ocf is None:
        ocf = info.get("operatingCashflow")
    put("ocf", ocf, ocf is not None and ocf > th["op_cash_flow_min"])

    # -- §2 Growth (CAGR) -------------------------------------------------- #
    yrs = th["cagr_years"]

    rev = _row(inc, ["Total Revenue", "Operating Revenue"])
    sg, sy = _cagr(rev, yrs)
    put("sales_g", sg, sg is not None and sg >= th["sales_growth_min"],
        note=_growth_note(sg, sy))

    prof = _row(inc, ["Net Income", "Net Income Common Stockholders"])
    pg, py = _cagr(prof, yrs)
    put("profit_g", pg, pg is not None and pg >= th["profit_growth_min"],
        note=_growth_note(pg, py))

    eps = _row(inc, ["Diluted EPS", "Basic EPS"])
    if eps is None:  # fall back to Net Income / share count
        ni_row = _row(inc, ["Net Income", "Net Income Common Stockholders"])
        sh_row = _row(inc, ["Diluted Average Shares", "Basic Average Shares"])
        if ni_row is not None and sh_row is not None:
            common = ni_row.index.intersection(sh_row.index)
            if len(common) >= 2:
                eps = (ni_row[common] / sh_row[common]).sort_index(ascending=False)
    eg, ey = _cagr(eps, yrs)
    put("eps_g", eg, eg is not None and eg >= th["eps_growth_min"],
        note=_growth_note(eg, ey))

    # -- classify ---------------------------------------------------------- #
    verdicts = [m[k]["verdict"] for k, _, _ in CHECKS]
    fails = sum(v == FAIL for v in verdicts)
    applicable = sum(v != NA for v in verdicts)
    if applicable < config.MIN_APPLICABLE:
        bucket = "insufficient"
    elif fails == 0:
        bucket = "eligible"
    elif fails == 1:
        bucket = "near-miss"
    else:
        bucket = "rejected"

    return {"ticker": ticker, "name": name, "sector": sector, "is_fin": is_fin,
            "currency": currency, "metrics": m, "fails": fails,
            "applicable": applicable, "bucket": bucket}


def _safe(fn):
    try:
        df = fn()
        return None if (df is None or df.empty) else df
    except Exception:
        return None


def _growth_note(rate, years):
    if rate is None:
        return "n/a (loss / sign change)" if years else ""
    return f"{years}y CAGR"


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #
def cell(key, d):
    v, verdict = d["value"], d["verdict"]
    mark = {"pass": "✓", "fail": "✗", "na": "·"}[verdict]  # ✓ ✗ ·
    if verdict == NA:
        return "n/a" + mark
    if key == "ocf":
        return ("+" if v and v > 0 else "–") + mark
    if key == "de":
        return f"{v:.1f}{mark}"
    return f"{v * 100:.0f}%{mark}"


def why(m):
    out = []
    for k, _, _ in CHECKS:
        d = m[k]
        if d["verdict"] != FAIL:
            continue
        v = d["value"]
        if k == "de":
            out.append(f"{LABELS[k]} {v:.1f}")
        elif k == "ocf":
            out.append(f"{LABELS[k]} –")
        else:
            out.append(f"{LABELS[k]} {v * 100:.0f}%")
    return ", ".join(out)


def table_row(r):
    cells = "".join(f"{cell(k, r['metrics'][k]):>7}" for k, _, _ in CHECKS)
    return f"  {r['ticker']:<14}{r['name'][:22]:<23}{cells}   {why(r['metrics'])}"


def header_row():
    cols = "".join(f"{h:>7}" for _, h, _ in CHECKS)
    return f"  {'TICKER':<14}{'NAME':<23}{cols}   WHY IT FAILS"


BUCKETS = [
    ("eligible",     "✅ ELIGIBLE  — passes every applicable check"),
    ("near-miss",    "⚠️  NEAR-MISS — fails exactly one"),
    ("rejected",     "❌ REJECTED  — fails two or more"),
    ("insufficient", "❔ INSUFFICIENT DATA — could not evaluate"),
]


def print_report(results, when):
    print("\n" + "=" * 78)
    print(f"  STOCK PRE-SCREEN   ·   §1 Quality + §2 Growth   ·   {when}")
    print("=" * 78)
    for key, title in BUCKETS:
        group = [r for r in results if r["bucket"] == key]
        print(f"\n{title}   ({len(group)})")
        if not group:
            print("  — none —")
            continue
        print(header_row())
        for r in sorted(group, key=lambda x: x["fails"]):
            print(table_row(r))
    print("\n" + "-" * 78)
    print("  Marks: ✓ pass  ✗ fail  · n/a   |   OCF row shows +/– sign only")
    print("  Ratios are unit-less, so mixing USD + INR is fine. N/A = data missing or")
    print("  not applicable (ROCE / debt for banks). Source: Yahoo Finance via yfinance.")
    print("-" * 78 + "\n")


def write_markdown(results, when, path):
    lines = [f"# Stock pre-screen — {when}", "",
             "Filter: **§1 Quality + §2 Growth**. First-pass only — valuation, moat "
             "and momentum are checked by hand.", ""]
    hdr = "| Ticker | Name | " + " | ".join(h for _, h, _ in CHECKS) + " | Why it fails |"
    sep = "|" + "---|" * (len(CHECKS) + 3)
    for key, title in BUCKETS:
        group = sorted([r for r in results if r["bucket"] == key], key=lambda x: x["fails"])
        lines += [f"## {title}  ({len(group)})", ""]
        if not group:
            lines += ["_none_", ""]
            continue
        lines += [hdr, sep]
        for r in group:
            cells = " | ".join(cell(k, r["metrics"][k]) for k, _, _ in CHECKS)
            lines.append(f"| {r['ticker']} | {r['name'][:40]} | {cells} | {why(r['metrics'])} |")
        lines.append("")
    lines += ["---",
              "_Source: Yahoo Finance via yfinance. Ratios are unit-less so USD/INR mix is "
              "fine. N/A = data missing or not applicable (e.g. ROCE / debt for banks)._"]
    path.write_text("\n".join(lines), encoding="utf-8")


def write_csv(results, path):
    keys = [k for k, _, _ in CHECKS]
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["ticker", "name", "sector", "currency", "bucket", "fails",
                    "applicable"] + keys)
        for r in results:
            row = [r["ticker"], r["name"], r["sector"], r["currency"],
                   r["bucket"], r["fails"], r["applicable"]]
            for k in keys:
                v = r["metrics"][k]["value"]
                row.append("" if v is None else round(float(v), 4))
            w.writerow(row)


# --------------------------------------------------------------------------- #
def read_watchlist(path):
    tickers = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            tickers.append(line.upper())
    return tickers


def main():
    wl_path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "watchlist.txt"
    if not wl_path.exists():
        sys.exit(f"Watchlist not found: {wl_path}")

    tickers = read_watchlist(wl_path)
    if not tickers:
        sys.exit("Watchlist is empty.")

    when = datetime.date.today().isoformat()
    print(f"Screening {len(tickers)} tickers from {wl_path.name} ...")

    results = []
    for i, tk in enumerate(tickers, 1):
        print(f"  [{i:>2}/{len(tickers)}] {tk:<14}", end="", flush=True)
        try:
            r = evaluate(tk)
            print(f"-> {r['bucket']}")
            results.append(r)
        except Exception as exc:
            print(f"-> error ({exc})")
            results.append({"ticker": tk, "name": tk, "sector": "", "is_fin": False,
                            "currency": "", "metrics": {k: {"value": None, "verdict": NA,
                            "note": ""} for k, _, _ in CHECKS}, "fails": 0,
                            "applicable": 0, "bucket": "insufficient"})
        time.sleep(0.4)  # be gentle with Yahoo

    print_report(results, when)

    reports = HERE / "reports"
    reports.mkdir(exist_ok=True)
    md, cv = reports / f"screen_{when}.md", reports / f"screen_{when}.csv"
    write_markdown(results, when, md)
    write_csv(results, cv)
    print(f"Saved:\n  {md}\n  {cv}\n")


if __name__ == "__main__":
    main()

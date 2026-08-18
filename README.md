# Stock pre-screen

A personal, first-pass stock filter. Point it at a watchlist and it flags which stocks
clear the quantitative basics — so you only spend real research time on the ones worth
it. It deliberately does **not** judge valuation, moat, management or momentum; you do
those by hand once a stock makes the shortlist.

Two parts, one repo:

- **`backend/`** — Python screening logic + a FastAPI service (data via Yahoo Finance).
- **`app/`** — Flutter app (web + Android) that calls the backend.

## The checklist it automates

| | Check | Rule |
|---|---|---|
| §1 | ROCE | > 20%  *(N/A for banks/financials)* |
| §1 | ROE | > 20% |
| §1 | Low debt | Debt/Equity < 0.5  *(N/A for banks/financials)* |
| §1 | Positive cash flow | Operating cash flow > 0 |
| §2 | Sales growth | 3-yr CAGR > 15% |
| §2 | Profit growth | 3-yr CAGR > 15% |
| §2 | EPS growth | 3-yr CAGR > 15% |

Each stock is bucketed: **Eligible** (passes every applicable check), **Near-miss**
(fails exactly one), **Rejected** (fails two or more), or **Insufficient data**. Missing
or not-applicable data is marked N/A, never a silent fail. Ratios are unit-less, so US
(USD) and Indian (INR) stocks run through the same checks with no currency conversion.

> **Ticker format:** US = plain symbol (`AAPL`). India = add a suffix — `.NS` (NSE) or
> `.BO` (BSE), e.g. `TCS.NS`. A bare Indian name won't resolve on Yahoo.

## Run the backend

```bash
# from the repo root
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
uvicorn --app-dir backend app:app --reload --port 8000
```

- Interactive API explorer: <http://127.0.0.1:8000/docs>
- `GET /screen` (uses `backend/watchlist.txt`) · `GET /screen?tickers=AAPL,TCS.NS` · `GET /stock/AAPL`

Or run the screener as a standalone CLI (prints a table + saves Markdown/CSV to `backend/reports/`):

```bash
python backend/screener.py
```

Edit **`backend/watchlist.txt`** for your stocks and **`backend/config.py`** for the thresholds.

## Run the app (web)

```bash
cd app
flutter pub get
flutter run -d chrome --web-port 5555
```

On web the app calls the backend at `http://127.0.0.1:8000`; on the Android emulator it
uses `http://10.0.2.2:8000`. Point it at a deployed backend with
`--dart-define=API_BASE=https://your-host`.

## Status / roadmap

- ✅ Backend API + Flutter web app
- ⏳ Android build (needs Android `cmdline-tools` + accepted SDK licenses)
- Ideas: SQLite cache + scheduled refresh; higher-quality data per market (SEC EDGAR for
  US, Screener.in for India); deploy backend (Cloud Run/Railway) + web (static host).

## Data caveats

Yahoo Finance (via `yfinance`) is free and broad but unofficial and occasionally patchy.
Treat the output as a *filter*, not gospel. Fundamentals update quarterly, so there's no
need to re-run daily.

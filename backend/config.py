# ---------------------------------------------------------------------------
# Pre-screen thresholds — edit these to taste. All growth/return values are
# fractions: 0.20 == 20%.
# ---------------------------------------------------------------------------

THRESHOLDS = {
    "roce_min":            0.20,   # §1  ROCE  > 20%
    "roe_min":             0.20,   # §1  ROE   > 20%
    "debt_to_equity_max":  0.50,   # §1  Debt/Equity < 0.5  ("low debt")
    "op_cash_flow_min":    0.0,    # §1  Operating cash flow must be > this (i.e. positive)
    "sales_growth_min":    0.15,   # §2  Revenue 3-yr CAGR  > 15%
    "profit_growth_min":   0.15,   # §2  Net-profit 3-yr CAGR > 15%
    "eps_growth_min":      0.15,   # §2  EPS 3-yr CAGR > 15%
    "cagr_years":          3,      # growth is measured over this many years (uses fewer if
                                   # that's all the data available, and tells you the span)
}

# Sectors treated as "financial": for banks/insurers/NBFCs, ROCE and Debt/Equity
# are meaningless, so those two checks are marked N/A instead of failed.
FINANCIAL_SECTORS = {"Financial Services"}

# A stock needs at least this many *applicable* (non-N/A) checks before it can be
# called "eligible" — stops a data-starved ticker from passing by having everything N/A.
MIN_APPLICABLE = 5

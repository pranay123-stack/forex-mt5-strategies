# Forex MT5 Strategies

Seven algorithmic trading strategies written as MetaTrader 5 Expert Advisors in MQL5, each
with Strategy Tester output and a written design document.

The through-line is oscillator construction: several of these build custom indicators from
parametric curves — Butterfly, Rose and Triple Sine — rather than reusing stock MT5
oscillators, then wrap them in trend filters and ATR-based risk sizing.

---

## Strategies

| EA | Approach |
|---|---|
| `ForexScalper_EA` | Pullback scalping with multi-confluence entry, H1 ATR dynamic stops |
| `PPCorr_EA` + `PseudoPC` | Pseudo-Pearson correlation across DeMarker, MFI and RSI with an RSI baseline |
| `TSO_MeanReversion_EA` | Triple Sine Oscillator mean reversion — `sin³(k·(Close−MA)/StdDev)` |
| `ButterflyOscillator_EA` | Butterfly-curve oscillator with a dual SMA trend filter |
| `FVI_EA` | Flower Volatility Index — Rose-curve derived oscillator, trend following |
| `VB_EA` | Volume Boundary oscillator with Butterfly / Triple Sine smoothing |
| `LiquidityMarketMap_EA` | SMC execution — iFVG, FVG, breaker and rejection blocks, multi-timeframe |

**Scope note:** `LiquidityMarketMap_EA` targets NQ/NASDAQ futures rather than FX pairs. It
lives here because it shares the MQL5 codebase and tooling, not because it is a forex
strategy.

---

## What's included

- **8 MQL5 source files** — the EAs above, buildable in MetaEditor
- **Strategy Tester reports** — HTML reports plus equity, MFE/MAE, holding-time and history
  charts for backtested EAs
- **Per-strategy design documents** — the logic written out before the code
- **MT5 workflow notes** — EA development flow, backtesting steps, live deployment steps,
  and broker account setup

---

## On the backtest reports

The reports are MetaTrader 5 Strategy Tester output on historical data. They are **backtests,
not live trading records**, and carry the usual limits: results depend on the broker's tick
history and spread model, and no forward-tested or live-traded results are published here.
Read them as evidence that the strategies run and were measured, not as performance claims.

---

## Running these

1. Copy an `.mq5` file into `MQL5/Experts/` in your MT5 data folder
2. Compile in MetaEditor (F7)
3. Attach to a chart, or run it in the Strategy Tester
4. `Forex_trading_setup/` contains the step-by-step notes for backtesting and live deployment

**Tech:** MQL5, MetaTrader 5

---

*Part of [Forex Trading Strategies](https://github.com/pranay123-stack/forex-trading-strategies) ·
related: [Algorithmic Trading](https://github.com/pranay123-stack/algorithmic-trading)*

# KBPARI Trading Bot

Clean rebuild of the KBPARI automated trading system.

## Architecture

Dashboard → Supabase → KBPARI Worker → MT5

- MT5: execution and live position state
- Worker: authenticated API and orchestration
- Supabase: configuration and persistent trading data
- Dashboard: control and monitoring

Supported symbols: XAUUSD, EURUSD, GBPUSD.

The new implementation is intentionally independent of the previous trading-bot repository.

## Trading configuration

`target_profit_pips` is read dynamically from Supabase. It must never be hard-coded in the MT5 EA.

`target_loss_pips` is generated automatically as `target_profit_pips × 2` and is display-only.

Changing Target Profit in the Dashboard therefore does not require recompiling the EA.

## Current implementation

### MT5 EA
- `mt5/botrading.mq5` version 1.000.
- Reads bot configuration dynamically from Worker `GET /config`.
- `target_profit_pips` is never hard-coded as a trading target.
- `target_loss_pips` is read from the generated Supabase configuration.
- Synchronizes heartbeat and open positions.
- Executes authenticated BUY/SELL signals from Worker.
- Closes managed positions when live profit reaches the configured target in pips.
- Detects positions that disappear from MT5 and reports the external/manual close.
- Does not print or execute `NONE` signals because the Worker filters them.

The EA is intentionally not tied to a particular dashboard target value. Changing Target Profit Pips in Supabase changes the value used by the running EA on its next configuration refresh; recompilation is not required.

### Worker signal flow
1. A valid signal is stored in `trading_signals` with status `NEW`.
2. MT5 polls `GET /signals`.
3. MT5 validates symbol, side, position limit and risk volume.
4. MT5 executes the market order.
5. MT5 reports the order/execution to the Worker.
6. The signal is marked `CONSUMED` (or `REJECTED`).

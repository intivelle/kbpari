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

# KBPARI Worker

Cloudflare Worker API between the Dashboard/MT5 clients and Supabase.

## Required secrets

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `BOT_API_KEY`

Secrets are runtime configuration and must not be committed to GitHub.

## Endpoints

- `GET /health` — public health check
- `GET /config` — authenticated bot configuration
- `POST /heartbeat` — MT5 heartbeat
- `GET /signals` — authenticated pending signals
- `POST /signals`\n- `POST /signals/consume` — create a signal
- `POST /orders` — submit an order record
- `GET /positions` — read positions
- `POST /positions` — synchronize a position
- `POST /execution`\n- `POST /transactions` — record an execution

The Worker reads target-profit settings dynamically from Supabase. It does not contain a hard-coded target-profit value.

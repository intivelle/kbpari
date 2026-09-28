# KBPARI Dashboard

Static Cloudflare Pages dashboard for the clean KBPARI rebuild.

## Tabs

- Overview
- Open Positions
- Today's Transactions
- Bot Settings
- Performance
- System

## Security model

The dashboard uses the Supabase publishable key and Supabase Auth. The Worker API key is never placed in browser code.

Target Profit Pips is editable. Target Loss Pips (Auto) is read-only and comes from the generated database value target_profit_pips × 2.

Set WORKER_URL in dashboard/app.js after the Worker has a deployed public URL. The dashboard will otherwise show Worker as NOT DEPLOYED.

## Cloudflare Pages

Deploy the dashboard directory as the Pages output/root directory for a static site. No build command is required.

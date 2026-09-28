import { ingestCandlesAndGenerate } from "./signal-engine.js";
const INVERSE_EXECUTION = false;

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};

function response(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...extraHeaders },
  });
}

function corsHeaders() {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "content-type, x-bot-key",
    "access-control-allow-methods": "GET, POST, OPTIONS",
  };
}

function withCors(resp) {
  const headers = new Headers(resp.headers);
  for (const [key, value] of Object.entries(corsHeaders())) {
    headers.set(key, value);
  }
  return new Response(resp.body, { status: resp.status, headers });
}

async function supabaseRequest(env, path, options = {}) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error("Supabase environment is not configured");
  }

  const headers = new Headers(options.headers || {});
  headers.set("apikey", env.SUPABASE_SERVICE_ROLE_KEY);
  headers.set("authorization", `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`);
  headers.set("content-type", "application/json");

  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
    ...options,
    headers,
  });

  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }

  if (!res.ok) {
    const message = typeof data === "object" && data?.message
      ? data.message
      : `Supabase HTTP ${res.status}`;
    throw new Error(message);
  }

  return data;
}

function isAuthorized(request, env) {
  const expected = env.BOT_API_KEY;
  if (!expected) return false;
  return request.headers.get("x-bot-key") === expected;
}

async function requireAuth(request, env) {
  if (!isAuthorized(request, env)) {
    return response({ success: false, error: "Unauthorized" }, 401);
  }
  return null;
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    throw new Error("Invalid JSON body");
  }
}

async function getConfig(env) {
  const rows = await supabaseRequest(
    env,
    "bot_config?select=id,enabled,mode,symbols,risk_percent,max_positions,max_daily_loss_percent,max_daily_trades,target_profit_pips,target_loss_pips,updated_at&limit=1"
  );
  return rows?.[0] || null;
}

async function handleHealth(env) {
  const started = Date.now();
  const config = await getConfig(env);

  return response({
    success: true,
    service: "kbpari-worker",
    version: env.WORKER_API_VERSION || "1.0.0",
    supabase: "connected",
    config_id: config?.id || null,
    bot_enabled: config?.enabled ?? false,
    mode: config?.mode || null,
    target_profit_pips: config?.target_profit_pips ?? null,
    target_loss_pips: config?.target_loss_pips ?? null,
    latency_ms: Date.now() - started,
    time: new Date().toISOString(),
  });
}

async function handleConfig(env) {
  const config = await getConfig(env);
  if (!config) {
    return response({ success: false, error: "Bot configuration not found" }, 404);
  }
  return response({ success: true, config });
}

async function handleHeartbeat(request, env) {
  const body = await readJson(request);
  if (!body.bot_id) throw new Error("bot_id is required");

  const row = {
    bot_id: body.bot_id,
    ea_version: body.ea_version ?? null,
    mt5_account: body.mt5_account ?? null,
    balance: body.balance ?? null,
    equity: body.equity ?? null,
    free_margin: body.free_margin ?? null,
    margin_level: body.margin_level ?? null,
    terminal_time: body.terminal_time ?? null,
    status: body.status ?? "ONLINE",
    metadata: body.metadata ?? {},
  };

  const data = await supabaseRequest(env, "bot_heartbeats", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(row),
  });

  return response({ success: true, heartbeat: data?.[0] ?? data });
}

async function handleSignalsGet(request, env) {
  const url = new URL(request.url);
  const requestedSymbol = url.searchParams.get("symbol");

  // Config and signal lookup stay independent so a slow config request cannot
  // unnecessarily delay signal delivery.
  const [config, data] = await Promise.all([
    getConfig(env),
    (async () => {
      const params = new URLSearchParams();
      params.set("select", "*");
      params.set("status", "eq.NEW");
      params.set("signal", "neq.NONE");
      params.set("order", "created_at.desc");
      params.set("limit", url.searchParams.get("limit") || "20");

      if (requestedSymbol) {
        params.set("symbol", "eq." + requestedSymbol);
      }

      return await supabaseRequest(env, "trading_signals?" + params.toString());
    })(),
  ]);

  if (!config) {
    await writeSignalDiagnostic(env, "SIGNAL_POLL_BLOCKED", "Bot configuration not found", requestedSymbol, {
      requested_symbol: requestedSymbol,
      reason: "NO_CONFIG",
    });
    return response({ success: true, signals: [] });
  }

  if (!config.enabled || config.mode !== "AUTO") {
    await writeSignalDiagnostic(env, "SIGNAL_POLL_BLOCKED", "Signal delivery disabled by bot configuration", requestedSymbol, {
      requested_symbol: requestedSymbol,
      enabled: config.enabled,
      mode: config.mode,
      reason: "CONFIG_DISABLED_OR_NOT_AUTO",
    });
    return response({ success: true, signals: [] });
  }

  const candidate = Array.isArray(data) ? data : [];

  // MT5 is the source of truth for live positions. The previous implementation
  // used a 60-second executions/CLOSE cooldown here. That could suppress a valid
  // NEW signal even when the signal itself was created before the close. Signal
  // delivery is now based only on the NEW signal queue; MT5 enforces max_positions
  // and position management.
  if (!candidate.length) {
    return response({ success: true, signals: [] });
  }

  const selected = candidate[0];
  const originalSignal = selected.signal;
  const executionSignal =
    INVERSE_EXECUTION && originalSignal === "BUY" ? "SELL" :
    INVERSE_EXECUTION && originalSignal === "SELL" ? "BUY" :
    originalSignal;

  // Preserve the original signal in Supabase. Only the signal delivered to
  // MT5 is inverted, so historical signal analysis remains unchanged.
  const delivered = {
    ...selected,
    signal: executionSignal,
  };

  await writeSignalDiagnostic(
    env,
    "SIGNAL_DELIVERY_CANDIDATE",
    "Candidate " + originalSignal + " will be delivered as " + executionSignal,
    selected.symbol,
    {
      signal_id: selected.id,
      signal_created_at: selected.created_at,
      signal_status: selected.status,
      original_signal: originalSignal,
      execution_signal: executionSignal,
      inverse_execution: INVERSE_EXECUTION,
      requested_symbol: requestedSymbol,
      candidate_count: candidate.length,
      signal_reason: selected.reason,
      signal_source: selected.source,
    }
  );

  // Keep the audit trail server-side so signal delivery can be reconstructed
  // even when the MT5 terminal log is unavailable.
  const s = selected;
  await supabaseRequest(env, "bot_logs", {
    method: "POST",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      level: "INFO",
      component: "WORKER",
      event: "SIGNAL_DELIVERED",
      message: "Signal " + originalSignal + " delivered to MT5 as " + executionSignal,
      symbol: s.symbol,
      mt5_ticket: null,
      metadata: {
        signal_id: s.id,
        confidence: s.confidence,
        signal_created_at: s.created_at,
        signal_reason: s.reason,
        signal_source: s.source,
        original_signal: originalSignal,
        execution_signal: executionSignal,
        inverse_execution: INVERSE_EXECUTION,
        candidate_count: candidate.length,
      }
    })
  });

  return response({ success: true, signals: [delivered] }, 200, {
    "x-kbpari-signal-id": String(selected.id),
  });
}

async function writeSignalDiagnostic(env, event, message, symbol, metadata = {}) {
  try {
    await supabaseRequest(env, "bot_logs", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        level: "INFO",
        component: "WORKER",
        event,
        message,
        symbol: symbol || null,
        mt5_ticket: null,
        metadata,
      }),
    });
  } catch {
    // Diagnostics must never prevent signal delivery.
  }
}

async function handleSignalsPost(request, env) {
  const body = await readJson(request);
  if (!body.symbol || !body.signal) {
    throw new Error("symbol and signal are required");
  }

  const config = await getConfig(env);
  if (!config) throw new Error("Bot configuration not found");
  if (!config.symbols?.includes(body.symbol)) {
    throw new Error("Symbol is not enabled");
  }
  if (!["BUY","SELL","CLOSE","NONE"].includes(body.signal)) {
    throw new Error("Invalid signal");
  }

  const row = {
    symbol: body.symbol,
    signal: body.signal,
    confidence: body.confidence ?? null,
    entry_price: body.entry_price ?? null,
    stop_loss: body.stop_loss ?? null,
    target_price: body.target_price ?? null,
    reason: body.reason ?? null,
    source: body.source ?? "BOT",
    status: body.status ?? "NEW",
  };

  const data = await supabaseRequest(env, "trading_signals", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(row),
  });

  return response({ success: true, signal: data?.[0] ?? data });
}


async function handleSignalConsume(request, env) {
  const body = await readJson(request);
  if (!body.id) throw new Error("id is required");

  const data = await supabaseRequest(
    env,
    `trading_signals?id=eq.${encodeURIComponent(body.id)}&status=eq.NEW`,
    {
      method: "PATCH",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        status: body.status ?? "CONSUMED",
        consumed_at: new Date().toISOString(),
      }),
    }
  );

  return response({ success: true, signal: data?.[0] ?? data });
}

async function handleOrdersPost(request, env) {
  const body = await readJson(request);
  if (!body.client_order_id || !body.symbol || !body.side || body.volume == null) {
    throw new Error("client_order_id, symbol, side and volume are required");
  }

  const row = {
    client_order_id: body.client_order_id,
    mt5_ticket: body.mt5_ticket ?? null,
    symbol: body.symbol,
    side: body.side,
    volume: body.volume,
    requested_price: body.requested_price ?? null,
    stop_loss: body.stop_loss ?? null,
    take_profit: body.take_profit ?? null,
    status: body.status ?? "PENDING",
    signal_id: body.signal_id ?? null,
    rejection_reason: body.rejection_reason ?? null,
  };

  const data = await supabaseRequest(env, "orders?on_conflict=client_order_id", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify(row),
  });

  return response({ success: true, order: data?.[0] ?? data });
}

async function handlePositionsGet(request, env) {
  const url = new URL(request.url);
  const status = url.searchParams.get("status") || "OPEN";
  const params = new URLSearchParams({
    select: "*",
    status: `eq.${status}`,
    order: "updated_at.desc",
  });

  const data = await supabaseRequest(env, `positions?${params.toString()}`);
  return response({ success: true, positions: data || [] });
}

async function handlePositionsPost(request, env) {
  const body = await readJson(request);
  if (body.mt5_ticket == null || !body.symbol || !body.side) {
    throw new Error("mt5_ticket, symbol and side are required");
  }

  const row = {
    mt5_ticket: body.mt5_ticket,
    symbol: body.symbol,
    side: body.side,
    volume: body.volume ?? null,
    entry_price: body.entry_price ?? null,
    current_price: body.current_price ?? null,
    stop_loss: body.stop_loss ?? null,
    take_profit: body.take_profit ?? null,
    pip_value: body.pip_value ?? null,
    pips: body.pips ?? null,
    floating_profit: body.floating_profit ?? null,
    status: body.status ?? "OPEN",
    opened_at: body.opened_at ?? null,
    closed_at: body.closed_at ?? null,
    close_reason: body.close_reason ?? null,
  };

  const data = await supabaseRequest(env, "positions?on_conflict=mt5_ticket", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify(row),
  });

  return response({ success: true, position: data?.[0] ?? data });
}

async function handleTransactionsPost(request, env) {
  const body = await readJson(request);
  if (body.mt5_ticket == null || !body.symbol || !body.side) {
    throw new Error("mt5_ticket, symbol and side are required");
  }

  const row = {
    mt5_ticket: body.mt5_ticket,
    symbol: body.symbol,
    side: body.side,
    volume: body.volume ?? 0,
    entry_price: body.entry_price ?? 0,
    stop_loss: body.stop_loss ?? null,
    close_price: body.close_price ?? 0,
    pips: body.pips ?? null,
    profit: body.profit ?? 0,
    close_reason: body.close_reason ?? "UNKNOWN",
    opened_at: body.opened_at ?? null,
    closed_at: body.closed_at ?? new Date().toISOString(),
  };

  const data = await supabaseRequest(env, "transactions?on_conflict=mt5_ticket", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify(row),
  });

  return response({ success: true, transaction: data?.[0] ?? data });
}

async function handleBotLogsPost(request, env) {
  const body = await readJson(request);
  const row = {
    level: body.level ?? "INFO",
    component: body.component ?? "UNKNOWN",
    event: body.event ?? "EVENT",
    message: body.message ?? "",
    symbol: body.symbol ?? null,
    mt5_ticket: body.mt5_ticket ?? null,
    metadata: body.metadata ?? {},
  };
  const data = await supabaseRequest(env, "bot_logs", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(row),
  });
  return response({ success: true, log: data?.[0] ?? data });
}

async function handleExecutionPost(request, env) {
  const body = await readJson(request);
  if (!body.action || !body.symbol) {
    throw new Error("action and symbol are required");
  }

  const row = {
    order_id: body.order_id ?? null,
    position_id: body.position_id ?? null,
    mt5_ticket: body.mt5_ticket ?? null,
    symbol: body.symbol,
    action: body.action,
    side: body.side ?? null,
    volume: body.volume ?? null,
    price: body.price ?? null,
    profit: body.profit ?? null,
    pips: body.pips ?? null,
    reason: body.reason ?? null,
    execution_status: body.execution_status ?? "SUCCESS",
    error_message: body.error_message ?? null,
    executed_at: body.executed_at ?? new Date().toISOString(),
  };

  const data = await supabaseRequest(env, "executions", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(row),
  });

  return response({ success: true, execution: data?.[0] ?? data });
}

async function route(request, env) {
  const url = new URL(request.url);

  if (request.method === "OPTIONS") {
    return response({ success: true });
  }

  if (request.method === "GET" && url.pathname === "/health") {
    return handleHealth(env);
  }
  if (request.method === "GET" && url.pathname === "/") {
    return response({
      success: true,
      service: "kbpari-worker",
      version: env.WORKER_API_VERSION || "1.0.0",
      message: "KBPARI Worker is running",
    });
  }

  const authError = await requireAuth(request, env);
  if (authError) return authError;

  if (request.method === "GET" && url.pathname === "/config") {
    return handleConfig(env);
  }
  if (request.method === "POST" && url.pathname === "/heartbeat") {
    return handleHeartbeat(request, env);
  }
  if (request.method === "GET" && url.pathname === "/signals") {
    return handleSignalsGet(request, env);
  }
  if (request.method === "POST" && url.pathname === "/market-data") {
    const body = await readJson(request);
    return response(await ingestCandlesAndGenerate(env, body));
  }
  if (request.method === "POST" && url.pathname === "/signals") {
    return handleSignalsPost(request, env);
  }
  if (request.method === "POST" && url.pathname === "/signals/consume") {
    return handleSignalConsume(request, env);
  }
  if (request.method === "POST" && url.pathname === "/orders") {
    return handleOrdersPost(request, env);
  }
  if (request.method === "GET" && url.pathname === "/positions") {
    return handlePositionsGet(request, env);
  }
  if (request.method === "POST" && url.pathname === "/positions") {
    return handlePositionsPost(request, env);
  }
  if (request.method === "POST" && url.pathname === "/transactions") {
    return handleTransactionsPost(request, env);
  }
  if (request.method === "POST" && url.pathname === "/execution") {
    return handleExecutionPost(request, env);
  }
  if (request.method === "POST" && url.pathname === "/bot-logs") {
    return handleBotLogsPost(request, env);
  }

  return response({ success: false, error: "Not found" }, 404);
}

export default {
  async fetch(request, env) {
    try {
      return withCors(await route(request, env));
    } catch (error) {
      return withCors(response({
        success: false,
        error: error instanceof Error ? error.message : "Internal error",
      }, 500));
    }
  },
};

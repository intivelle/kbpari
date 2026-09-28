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
  const params = new URLSearchParams();
  params.set("select", "*");
  params.set("status", "eq.NEW");
  params.set("signal", "neq.NONE");
  params.set("order", "created_at.asc");
  params.set("limit", url.searchParams.get("limit") || "20");

  const symbol = url.searchParams.get("symbol");
  if (symbol) params.set("symbol", `eq.${symbol}`);

  const data = await supabaseRequest(env, `trading_signals?${params.toString()}`);
  return response({ success: true, signals: data || [] });
}

async function handleSignalsPost(request, env) {
  const body = await readJson(request);
  if (!body.symbol || !body.signal) {
    throw new Error("symbol and signal are required");
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
  if (request.method === "POST" && url.pathname === "/signals") {
    return handleSignalsPost(request, env);
  }
  if (request.method === "POST" && url.pathname === "/signals/consume") {\n    return handleSignalConsume(request, env);\n  }\n  if (request.method === "POST" && url.pathname === "/orders") {
    return handleOrdersPost(request, env);
  }
  if (request.method === "GET" && url.pathname === "/positions") {
    return handlePositionsGet(request, env);
  }
  if (request.method === "POST" && url.pathname === "/positions") {
    return handlePositionsPost(request, env);
  }
  if (request.method === "POST" && url.pathname === "/transactions") {\n    return handleTransactionsPost(request, env);\n  }\n  if (request.method === "POST" && url.pathname === "/execution") {
    return handleExecutionPost(request, env);
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

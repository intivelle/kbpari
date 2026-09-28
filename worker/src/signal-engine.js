function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

async function db(env, path, options = {}) {
  const headers = new Headers(options.headers || {});
  headers.set("apikey", env.SUPABASE_SERVICE_ROLE_KEY);
  headers.set("authorization", `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`);
  headers.set("content-type", "application/json");
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, { ...options, headers });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) throw new Error(typeof data === "object" && data?.message ? data.message : `Supabase HTTP ${res.status}`);
  return data;
}

function ema(values, period) {
  if (values.length < period) return null;
  let value = values.slice(0, period).reduce((a, b) => a + b, 0) / period;
  const k = 2 / (period + 1);
  for (let i = period; i < values.length; i++) value = values[i] * k + value * (1 - k);
  return value;
}

function atr(candles, period = 14) {
  if (candles.length < period + 1) return null;
  const trs = [];
  for (let i = 1; i < candles.length; i++) {
    const c = candles[i];
    const p = candles[i - 1];
    trs.push(Math.max(c.high - c.low, Math.abs(c.high - p.close), Math.abs(c.low - p.close)));
  }
  if (trs.length < period) return null;
  let value = trs.slice(0, period).reduce((a, b) => a + b, 0) / period;
  for (let i = period; i < trs.length; i++) value = ((value * (period - 1)) + trs[i]) / period;
  return value;
}

function decimals(symbol) {
  return symbol === "XAUUSD" ? 2 : 5;
}

export async function generateSignal(env, symbol) {
  // Only evaluate candles that are current (or at most 90 seconds ahead).
  // Older bad/future rows must not become the "last" candle and cause the
  // same signal reason to be reported as duplicate on every new MT5 upload.
  const signalNowIso = new Date(Date.now() + 90 * 1000).toISOString();
  const rows = await db(
    env,
    `market_candles?select=candle_time,open,high,low,close,volume&symbol=eq.${encodeURIComponent(symbol)}&timeframe=eq.M1&candle_time=lte.${encodeURIComponent(signalNowIso)}&order=candle_time.desc&limit=120`
  );

  if (!rows || rows.length < 30) {
    return { generated: false, reason: "not_enough_candles", count: rows?.length || 0 };
  }

  const candles = [...rows].reverse();
  const closes = candles.map(c => Number(c.close));
  const last = candles[candles.length - 1];
  const previous = candles[candles.length - 2];

  const configRows = await db(
    env,
    "bot_config?select=enabled,mode,target_profit_pips,target_loss_pips&limit=1"
  );
  const botConfig = configRows?.[0];
  if (!botConfig) return { generated: false, reason: "bot_config_unavailable" };
  if (!botConfig.enabled || botConfig.mode !== "AUTO") {
    return { generated: false, reason: "bot_not_in_auto" };
  }

  const ema9Now = ema(closes, 9);
  const ema21Now = ema(closes, 21);
  const ema9Prev = ema(closes.slice(0, -1), 9);
  const ema21Prev = ema(closes.slice(0, -1), 21);
  const atr14 = atr(candles, 14);

  if (![ema9Now, ema21Now, ema9Prev, ema21Prev, atr14].every(Number.isFinite) || atr14 <= 0) {
    return { generated: false, reason: "indicator_unavailable" };
  }

  // Trend-following entry model:
  // Entry is driven by the current trend, with ONE completed candle
  // confirming the direction. ATR filters genuinely flat conditions.
  const emaGapNow = ema9Now - ema21Now;
  const emaGapPrev = ema9Prev - ema21Prev;
  const ema9Slope = ema9Now - ema9Prev;
  const ema21Slope = ema21Now - ema21Prev;
  const closeNow = Number(last.close);
  const closePrev = Number(previous.close);
  const atrThreshold = atr14 * 0.001;
  const trendStrength = Math.abs(emaGapNow) / atr14;

  // One-candle confirmation replaces the previous 3-candle sequence.
  const bullishCandle = closeNow > closePrev;
  const bearishCandle = closeNow < closePrev;

  const bullishTrend =
    emaGapNow > 0 &&
    ema9Slope > atrThreshold &&
    ema21Slope >= -atrThreshold &&
    trendStrength >= 0.005 &&
    bullishCandle;

  const bearishTrend =
    emaGapNow < 0 &&
    ema9Slope < -atrThreshold &&
    ema21Slope <= atrThreshold &&
    trendStrength >= 0.01 &&
    bearishCandle;

  let action = null;
  let reason = null;

  if (bullishTrend) {
    action = "BUY";
    reason = "TREND_BUY|" + last.candle_time;
  } else if (bearishTrend) {
    action = "SELL";
    reason = "TREND_SELL|" + last.candle_time;
  } else {
    const trendState = bullishTrend ? "BULLISH" : bearishTrend ? "BEARISH" : "NEUTRAL";
    return {
      generated: false,
      reason: "no_entry_setup",
      candle_time: last.candle_time,
      indicators: {
        ema9_prev: Number(ema9Prev.toFixed(6)),
        ema21_prev: Number(ema21Prev.toFixed(6)),
        ema_gap_prev: Number(emaGapPrev.toFixed(6)),
        ema9: Number(ema9Now.toFixed(6)),
        ema21: Number(ema21Now.toFixed(6)),
        ema_gap: Number(emaGapNow.toFixed(6)),
        ema9_slope: Number(ema9Slope.toFixed(6)),
        ema21_slope: Number(ema21Slope.toFixed(6)),
        atr14: Number(atr14.toFixed(6)),
        trend_strength_atr: Number(trendStrength.toFixed(4)),
        trend_state: trendState,
        pullback_reclaim: false,
        close: Number(closeNow.toFixed(6))
      }
    };
  }

  const existing = await db(
    env,
    `trading_signals?select=id,status&symbol=eq.${encodeURIComponent(symbol)}&reason=eq.${encodeURIComponent(reason)}&limit=1`
  );
  if (existing?.length) {
    return { generated: false, reason: "duplicate", signal_id: existing[0].id };
  }

  const price = Number(last.close);
  const targetLossPips = Number(botConfig.target_loss_pips);
  if (!Number.isFinite(targetLossPips) || targetLossPips <= 0) {
    return { generated: false, reason: "invalid_target_loss_pips" };
  }

  // Broker-side protection must match the dashboard-controlled Target Loss.
  // XAUUSD: 1 pip = 0.01 price. FX: 1 pip = 0.0001 price.
  const pipSize = symbol === "XAUUSD" ? 0.01 : 0.0001;
  const stopDistance = targetLossPips * pipSize;
  const stopLoss = action === "BUY" ? price - stopDistance : price + stopDistance;
  const precision = decimals(symbol);

  const confidence = Math.min(0.95, Math.max(0.60, 0.65 + Math.min(0.25, Math.abs(ema9Now - ema21Now) / atr14 * 0.10)));

  const signal = {
    symbol,
    signal: action,
    confidence: Number(confidence.toFixed(4)),
    entry_price: Number(price.toFixed(precision)),
    stop_loss: Number(stopLoss.toFixed(precision)),
    target_price: null,
    reason,
    source: "EMA9_EMA21_ATR14_AGGRESSIVE_1CANDLE",
    status: "NEW"
  };

  const created = await db(env, "trading_signals", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify(signal)
  });

  return { generated: true, signal: created?.[0] || created, indicators: {
    ema9: ema9Now,
    ema21: ema21Now,
    atr14
  }};
}

export async function ingestCandlesAndGenerate(env, body) {
  if (!body?.symbol || !Array.isArray(body?.candles)) {
    throw new Error("symbol and candles are required");
  }
  const symbol = body.symbol;
  const timeframe = body.timeframe || "M1";
  if (!["XAUUSD", "EURUSD", "GBPUSD"].includes(symbol)) throw new Error("Symbol is not enabled");
  if (timeframe !== "M1") throw new Error("Only M1 is supported");
  if (body.candles.length < 30) throw new Error("At least 30 candles are required");

  const sourceCandles = body.candles.slice(-120);

  // MT5 candle timestamps arrive as Unix epoch seconds (or milliseconds).
  // Unix epoch timestamps are absolute UTC instants; they must NOT be shifted by
  // a guessed broker/server timezone. The previous implementation tried to
  // subtract 0..14 hours to make the newest candle close to Date.now(), which
  // could move valid candles several hours backward and cause the strategy to
  // evaluate the wrong market state.
  //
  // Keep the timestamp exactly as supplied by MT5. We only normalize seconds
  // to milliseconds for ISO formatting.

  const rows = sourceCandles.map(c => ({
    symbol,
    timeframe,
    candle_time: (() => {
      const rawTime = Number(c.time);
      const rawMs = Number.isFinite(rawTime)
        ? (rawTime < 100000000000 ? rawTime * 1000 : rawTime)
        : new Date(c.time).getTime();
      if (!Number.isFinite(rawMs)) throw new Error("Invalid candle time");
      return new Date(rawMs).toISOString();
    })(),
    open: Number(c.open),
    high: Number(c.high),
    low: Number(c.low),
    close: Number(c.close),
    volume: Number(c.volume || 0)
  }));

  const validRows = rows.filter(row =>
    [row.open, row.high, row.low, row.close].every(Number.isFinite)
  );

  if (validRows.length < 30) {
    throw new Error("At least 30 valid candles are required");
  }

  // IMPORTANT: Upsert all candles in one Supabase request.
  // Sending one request per candle exceeds the Cloudflare Workers
  // subrequest limit when a batch contains up to 120 candles.
  await db(env, "market_candles?on_conflict=symbol,timeframe,candle_time", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(validRows)
  });

  const generated = await generateSignal(env, symbol);
  return {
    success: true,
    symbol,
    timeframe,
    candles_received: validRows.length,
    newest_candle_time: validRows
      .map(row => row.candle_time)
      .sort()
      .at(-1) || null,
    signal: generated
  };
}

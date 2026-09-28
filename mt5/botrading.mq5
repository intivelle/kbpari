#property strict
#property version   "1.041"
#property description "KBPARI MT5 Expert Advisor - dynamic configuration from Worker/Supabase"

#include <Trade/Trade.mqh>

CTrade trade;

input string InpWorkerURL = "https://kbpari.pbahagia433.workers.dev";
input string InpBotAPIKey = "kbpari_live_9f3c8a2e71d64b5aa9c7e14f3b82d6a1c5e8f0b27d49a61";
input string InpBotID = "MT5-01";
input int    InpTimerSeconds = 5;
input int    InpConfigRefreshSeconds = 10;
input int    InpHttpTimeoutMs = 5000;
input bool   InpAllowTrading = true;

string   g_worker_url = "";
string   g_api_key = "";
datetime g_last_config_fetch = 0;
datetime g_last_sync = 0;
bool     g_bot_enabled = false;
string   g_bot_mode = "PAUSED";
double   g_target_profit_pips = 0.0;
double   g_target_loss_pips = 0.0;
double   g_risk_percent = 0.25;
int      g_max_positions = 3;
string   g_symbols[];
ulong    g_bot_closed_tickets[];

struct PositionSnapshot
{
   ulong ticket;
   string symbol;
   ENUM_POSITION_TYPE type;
   double volume;
   double open_price;
   double current_price;
   double profit;
   double pips;
};

string JsonEscape(string value)
{
   string slash = CharToString(92);
   string quote = CharToString(34);

   StringReplace(value, slash, slash + slash);
   StringReplace(value, quote, slash + quote);
   StringReplace(value, CharToString(13), slash + "r");
   StringReplace(value, CharToString(10), slash + "n");

   return value;
}

bool HttpRequest(string method, string path, string body,
                 string &response_text, int &status_code)
{
   response_text = "";
   status_code = 0;

   if(StringLen(g_worker_url) < 8 || StringLen(g_api_key) == 0)
      return false;

   string url = g_worker_url + path;

   string headers =
      "Content-Type: application/json\r\n"
      "X-Bot-Key: " + g_api_key + "\r\n";

   char data[];
   char result[];
   string result_headers = "";

   if(StringLen(body) > 0)
      StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   else
      ArrayResize(data, 0);

   ResetLastError();

   status_code =
      WebRequest(
         method,
         url,
         headers,
         InpHttpTimeoutMs,
         data,
         result,
         result_headers
      );

   if(status_code == 1003)
   {
      int first_error = GetLastError();

      PrintFormat(
         "[KBPARI] WebRequest internal 1003 path=%s error=%d; retrying once",
         path,
         first_error
      );

      Sleep(250);

      ArrayResize(result, 0);
      result_headers = "";

      ResetLastError();

      status_code =
         WebRequest(
            method,
            url,
            headers,
            InpHttpTimeoutMs,
            data,
            result,
            result_headers
         );
   }

   if(status_code < 0)
   {
      int error_code = GetLastError();

      PrintFormat(
         "[KBPARI] WebRequest failed path=%s error=%d",
         path,
         error_code
      );

      return false;
   }

   if(status_code == 1003)
   {
      int error_code = GetLastError();

      response_text =
         CharArrayToString(
            result,
            0,
            -1,
            CP_UTF8
         );

      PrintFormat(
         "[KBPARI] WebRequest failed with internal 1003 after retry path=%s error=%d response=%s",
         path,
         error_code,
         response_text
      );

      status_code = -1;

      return false;
   }

   response_text =
      CharArrayToString(
         result,
         0,
         -1,
         CP_UTF8
      );

   return true;
}

string JsonString(string json, string key, string fallback="")
{
   string needle =
      CharToString(34) +
      key +
      CharToString(34) +
      ":";

   int p = StringFind(json, needle);

   if(p < 0)
      return fallback;

   p += StringLen(needle);

   while(
      p < StringLen(json) &&
      (
         StringGetCharacter(json,p) == ' ' ||
         StringGetCharacter(json,p) == '\t'
      )
   )
   {
      p++;
   }

   if(
      p >= StringLen(json) ||
      StringGetCharacter(json,p) != 34
   )
   {
      return fallback;
   }

   p++;

   int e = p;

   while(e < StringLen(json))
   {
      if(
         StringGetCharacter(json,e) == 34 &&
         (
            e == p ||
            StringGetCharacter(json,e-1) != 92
         )
      )
      {
         break;
      }

      e++;
   }

   if(e >= StringLen(json))
      return fallback;

   return StringSubstr(json,p,e-p);
}

double JsonNumber(string json, string key, double fallback=0.0)
{
   string needle =
      CharToString(34) +
      key +
      CharToString(34) +
      ":";

   int p = StringFind(json, needle);

   if(p < 0)
      return fallback;

   p += StringLen(needle);

   while(
      p < StringLen(json) &&
      (
         StringGetCharacter(json,p) == ' ' ||
         StringGetCharacter(json,p) == '\t'
      )
   )
   {
      p++;
   }

   int e = p;

   while(e < StringLen(json))
   {
      ushort c =
         StringGetCharacter(json,e);

      if(
         (c >= '0' && c <= '9') ||
         c == '-' ||
         c == '+' ||
         c == '.' ||
         c == 'e' ||
         c == 'E'
      )
      {
         e++;
      }
      else
      {
         break;
      }
   }

   if(e <= p)
      return fallback;

   return StringToDouble(
      StringSubstr(json,p,e-p)
   );
}

bool JsonBool(string json, string key, bool fallback=false)
{
   string needle =
      CharToString(34) +
      key +
      CharToString(34) +
      ":";

   int p = StringFind(json, needle);

   if(p < 0)
      return fallback;

   p += StringLen(needle);

   while(
      p < StringLen(json) &&
      (
         StringGetCharacter(json,p) == ' ' ||
         StringGetCharacter(json,p) == '\t'
      )
   )
   {
      p++;
   }

   if(StringSubstr(json,p,4) == "true")
      return true;

   if(StringSubstr(json,p,5) == "false")
      return false;

   return fallback;
}

double PipSize(string symbol)
{
   double point =
      SymbolInfoDouble(
         symbol,
         SYMBOL_POINT
      );

   int digits =
      (int)SymbolInfoInteger(
         symbol,
         SYMBOL_DIGITS
      );

   if(digits == 3 || digits == 5)
      return point * 10.0;

   return point;
}

double PositionPips(
   string symbol,
   ENUM_POSITION_TYPE type,
   double open_price,
   double current_price
)
{
   double pip =
      PipSize(symbol);

   if(pip <= 0.0)
      return 0.0;

   if(type == POSITION_TYPE_BUY)
      return (current_price - open_price) / pip;

   return (open_price - current_price) / pip;
}

int OpenPositionCount()
{
   int count = 0;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0 ||
         !PositionSelectByTicket(ticket))
      {
         continue;
      }

      string symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      if(IsManagedSymbol(symbol))
         count++;
   }

   return count;
}

bool WasBotClosed(ulong ticket)
{
   for(
      int i=0;
      i<ArraySize(g_bot_closed_tickets);
      i++
   )
   {
      if(g_bot_closed_tickets[i] == ticket)
         return true;
   }

   return false;
}

void RememberBotClosed(ulong ticket)
{
   if(ticket == 0 ||
      WasBotClosed(ticket))
   {
      return;
   }

   int n =
      ArraySize(
         g_bot_closed_tickets
      );

   ArrayResize(
      g_bot_closed_tickets,
      n + 1
   );

   g_bot_closed_tickets[n] = ticket;
}

void ForgetBotClosed(ulong ticket)
{
   for(
      int i=0;
      i<ArraySize(g_bot_closed_tickets);
      i++
   )
   {
      if(g_bot_closed_tickets[i] == ticket)
      {
         for(
            int j=i;
            j<ArraySize(g_bot_closed_tickets)-1;
            j++
         )
         {
            g_bot_closed_tickets[j] =
               g_bot_closed_tickets[j+1];
         }

         ArrayResize(
            g_bot_closed_tickets,
            ArraySize(g_bot_closed_tickets)-1
         );

         return;
      }
   }
}

bool IsManagedSymbol(string symbol)
{
   if(symbol != _Symbol)
      return false;

   if(ArraySize(g_symbols) == 0)
      return true;

   for(
      int i=0;
      i<ArraySize(g_symbols);
      i++
   )
   {
      if(g_symbols[i] == _Symbol)
         return true;
   }

   return false;
}

void ParseSymbols(string json)
{
   ArrayResize(g_symbols, 0);

   int p =
      StringFind(
         json,
         CharToString(34) +
         "symbols" +
         CharToString(34) +
         ":["
      );

   if(p < 0)
      return;

   p +=
      StringLen(
         CharToString(34) +
         "symbols" +
         CharToString(34) +
         ":["
      );

   int end =
      StringFind(
         json,
         "]",
         p
      );

   if(end < 0)
      return;

   string section =
      StringSubstr(
         json,
         p,
         end-p
      );

   int cursor = 0;

   while(cursor < StringLen(section))
   {
      int q1 =
         StringFind(
            section,
            CharToString(34),
            cursor
         );

      if(q1 < 0)
         break;

      int q2 =
         StringFind(
            section,
            CharToString(34),
            q1+1
         );

      if(q2 < 0)
         break;

      string symbol =
         StringSubstr(
            section,
            q1+1,
            q2-q1-1
         );

      if(StringLen(symbol) > 0)
      {
         int n =
            ArraySize(g_symbols);

         ArrayResize(
            g_symbols,
            n+1
         );

         g_symbols[n] = symbol;
      }

      cursor = q2 + 1;
   }
}

bool RefreshConfig()
{
   string body;
   int status;

   if(!HttpRequest(
         "GET",
         "/config",
         "",
         body,
         status))
   {
      return false;
   }

   if(status != 200)
   {
      PrintFormat(
         "[KBPARI] Config HTTP %d",
         status
      );

      return false;
   }

   int config_pos =
      StringFind(
         body,
         CharToString(34) +
         "config" +
         CharToString(34) +
         ":"
      );

   if(config_pos < 0)
   {
      Print(
         "[KBPARI] Invalid config response"
      );

      return false;
   }

   g_bot_enabled =
      JsonBool(
         body,
         "enabled",
         false
      );

   g_bot_mode =
      JsonString(
         body,
         "mode",
         "PAUSED"
      );

   g_target_profit_pips =
      JsonNumber(
         body,
         "target_profit_pips",
         0.0
      );

   g_target_loss_pips =
      JsonNumber(
         body,
         "target_loss_pips",
         g_target_profit_pips * 2.0
      );

   g_risk_percent =
      JsonNumber(
         body,
         "risk_percent",
         0.25
      );

   g_max_positions =
      (int)JsonNumber(
         body,
         "max_positions",
         3.0
      );

   ParseSymbols(body);

   g_last_config_fetch =
      TimeCurrent();

   PrintFormat(
      "[KBPARI] Config synced: enabled=%s mode=%s target_profit=%.2f pip target_loss=%.2f pip max_positions=%d",
      g_bot_enabled ? "true" : "false",
      g_bot_mode,
      g_target_profit_pips,
      g_target_loss_pips,
      g_max_positions
   );

   return true;
}

void SendHeartbeat()
{
   string body =
      StringFormat(
         "{\"bot_id\":\"%s\",\"ea_version\":\"%s\",\"mt5_account\":%I64d,\"balance\":%.2f,\"equity\":%.2f,\"free_margin\":%.2f,\"margin_level\":%.2f,\"terminal_time\":\"%s\",\"status\":\"ONLINE\",\"metadata\":{\"symbol\":\"%s\",\"chart_period\":%d}}",
         JsonEscape(InpBotID),
         "1.040",
         AccountInfoInteger(ACCOUNT_LOGIN),
         AccountInfoDouble(ACCOUNT_BALANCE),
         AccountInfoDouble(ACCOUNT_EQUITY),
         AccountInfoDouble(ACCOUNT_MARGIN_FREE),
         AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),
         TimeToString(
            TimeCurrent(),
            TIME_DATE|TIME_SECONDS
         ),
         JsonEscape(_Symbol),
         Period()
      );

   string response_text;
   int status;

   HttpRequest(
      "POST",
      "/heartbeat",
      body,
      response_text,
      status
   );
}

bool SendMarketData()
{
   string symbol = _Symbol;

   if(!IsManagedSymbol(symbol))
      return false;

   static datetime last_sent = 0;

   if(!SymbolSelect(symbol, true))
      return false;

   MqlRates refresh_rates[];

   ArraySetAsSeries(
      refresh_rates,
      true
   );

   ResetLastError();

   CopyRates(
      symbol,
      PERIOD_M1,
      0,
      2,
      refresh_rates
   );

   datetime closed_bar_time =
      iTime(
         symbol,
         PERIOD_M1,
         1
      );

   if(
      closed_bar_time <= 0 ||
      closed_bar_time == last_sent
   )
   {
      return false;
   }

   const int requested_candles = 80;

   // MT5 iTime() uses broker/server time. The Worker stores UTC.
   // Convert the broker-server candle timestamps to UTC explicitly.
   // This replaces the old Worker-side timezone guessing and keeps the
   // conversion deterministic for historical candles as well.
   int server_utc_offset = (int)(TimeCurrent() - TimeGMT());

   int copied = 0;

   string body =
      StringFormat(
         "{\"symbol\":\"%s\",\"timeframe\":\"M1\",\"candles\":[",
         JsonEscape(symbol)
      );

   for(
      int shift=requested_candles;
      shift>=1;
      shift--
   )
   {
      datetime bar_time =
         iTime(
            symbol,
            PERIOD_M1,
            shift
         );

      if(bar_time <= 0)
         continue;

      double bar_open =
         iOpen(
            symbol,
            PERIOD_M1,
            shift
         );

      double bar_high =
         iHigh(
            symbol,
            PERIOD_M1,
            shift
         );

      double bar_low =
         iLow(
            symbol,
            PERIOD_M1,
            shift
         );

      double bar_close =
         iClose(
            symbol,
            PERIOD_M1,
            shift
         );

      long bar_volume =
         (long)iVolume(
            symbol,
            PERIOD_M1,
            shift
         );

      if(
         bar_open <= 0.0 ||
         bar_high <= 0.0 ||
         bar_low <= 0.0 ||
         bar_close <= 0.0
      )
      {
         continue;
      }

      if(copied > 0)
         body += ",";

      datetime utc_bar_time = bar_time - server_utc_offset;

      body +=
         StringFormat(
            "{\"time\":%I64d,\"open\":%.10f,\"high\":%.10f,\"low\":%.10f,\"close\":%.10f,\"volume\":%I64d}",
            (long)utc_bar_time,
            bar_open,
            bar_high,
            bar_low,
            bar_close,
            bar_volume
         );

      copied++;
   }

   if(copied < 30)
      return false;

   body += "]}";

   string response_text;
   int status;

   if(
      HttpRequest(
         "POST",
         "/market-data",
         body,
         response_text,
         status
      ) &&
      status >= 200 &&
      status < 300
   )
   {
      last_sent = closed_bar_time;

      PrintFormat(
         "[%s] Market data submitted closed_bar=%s terminal=%s",
         symbol,
         TimeToString(
            closed_bar_time,
            TIME_DATE|TIME_SECONDS
         ),
         TimeToString(
            TimeCurrent(),
            TIME_DATE|TIME_SECONDS
         )
      );

      string signal_result =
         JsonString(
            response_text,
            "reason",
            "processed"
         );

      bool generated =
         (
            StringFind(
               response_text,
               "\"generated\":true"
            ) >= 0
         );

      if(generated)
      {
         PrintFormat(
            "[%s] Market data OK candles=%d signal=GENERATED",
            symbol,
            copied
         );
      }
      else
      {
         string candle_time =
            JsonString(
               response_text,
               "candle_time",
               ""
            );

         double ema9_prev =
            JsonNumber(
               response_text,
               "ema9_prev",
               0.0
            );

         double ema21_prev =
            JsonNumber(
               response_text,
               "ema21_prev",
               0.0
            );

         double ema_gap_prev =
            JsonNumber(
               response_text,
               "ema_gap_prev",
               0.0
            );

         double ema9 =
            JsonNumber(
               response_text,
               "ema9",
               0.0
            );

         double ema21 =
            JsonNumber(
               response_text,
               "ema21",
               0.0
            );

         double ema_gap =
            JsonNumber(
               response_text,
               "ema_gap",
               0.0
            );

         string cross_state =
            JsonString(
               response_text,
               "cross_state",
               "UNKNOWN"
            );

         if(
            StringLen(candle_time) > 0 &&
            ema9 > 0.0 &&
            ema21 > 0.0
         )
         {
            PrintFormat(
               "[%s] Market data OK candles=%d signal=NONE reason=%s candle=%s prev(EMA9=%.5f EMA21=%.5f gap=%.5f) now(EMA9=%.5f EMA21=%.5f gap=%.5f) state=%s",
               symbol,
               copied,
               signal_result,
               candle_time,
               ema9_prev,
               ema21_prev,
               ema_gap_prev,
               ema9,
               ema21,
               ema_gap,
               cross_state
            );
         }
         else
         {
            PrintFormat(
               "[%s] Market data OK candles=%d signal=NONE reason=%s",
               symbol,
               copied,
               signal_result
            );
         }
      }

      return true;
   }

   if(status > 0)
   {
      PrintFormat(
         "[%s] Market data HTTP %d response=%s",
         symbol,
         status,
         response_text
      );
   }

   return false;
}

bool SendPositionSnapshot(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol =
      PositionGetString(
         POSITION_SYMBOL
      );

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(
         POSITION_TYPE
      );

   double volume =
      PositionGetDouble(
         POSITION_VOLUME
      );

   double open_price =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   double current_price =
      PositionGetDouble(
         POSITION_PRICE_CURRENT
      );

   double profit =
      PositionGetDouble(
         POSITION_PROFIT
      );

   double pips =
      PositionPips(
         symbol,
         type,
         open_price,
         current_price
      );

   string side =
      (
         type == POSITION_TYPE_BUY
         ? "BUY"
         : "SELL"
      );

   string body =
      StringFormat(
         "{\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"entry_price\":%.8f,\"current_price\":%.8f,\"stop_loss\":%.8f,\"take_profit\":%.8f,\"pip_value\":%.8f,\"pips\":%.2f,\"floating_profit\":%.2f,\"status\":\"OPEN\",\"opened_at\":\"%s\"}",
         ticket,
         JsonEscape(symbol),
         side,
         volume,
         open_price,
         current_price,
         PositionGetDouble(POSITION_SL),
         PositionGetDouble(POSITION_TP),
         PipSize(symbol),
         pips,
         profit,
         TimeToString(
            (datetime)PositionGetInteger(POSITION_TIME),
            TIME_DATE|TIME_SECONDS
         )
      );

   string response_text;
   int status;

   return
      HttpRequest(
         "POST",
         "/positions",
         body,
         response_text,
         status
      ) &&
      status >= 200 &&
      status < 300;
}

bool SendTransaction(
   ulong ticket,
   string symbol,
   string side,
   double volume,
   double entry_price,
   double stop_loss,
   double close_price,
   double pips,
   double profit,
   string reason,
   datetime opened_at,
   datetime closed_at
)
{
   string body =
      StringFormat(
         "{\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"entry_price\":%.8f,\"stop_loss\":%.8f,\"close_price\":%.8f,\"pips\":%.2f,\"profit\":%.2f,\"close_reason\":\"%s\",\"opened_at\":\"%s\",\"closed_at\":\"%s\"}",
         ticket,
         JsonEscape(symbol),
         JsonEscape(side),
         volume,
         entry_price,
         stop_loss,
         close_price,
         pips,
         profit,
         JsonEscape(reason),
         TimeToString(
            opened_at,
            TIME_DATE|TIME_SECONDS
         ),
         TimeToString(
            closed_at,
            TIME_DATE|TIME_SECONDS
         )
      );

   string response_text;
   int status;

   return
      HttpRequest(
         "POST",
         "/transactions",
         body,
         response_text,
         status
      ) &&
      status >= 200 &&
      status < 300;
}

bool MarkPositionClosed(
   ulong ticket,
   string symbol,
   string side,
   double volume,
   double entry_price,
   double close_price,
   double pips,
   double profit,
   string reason,
   datetime opened_at,
   datetime closed_at
)
{
   string body =
      StringFormat(
         "{\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"entry_price\":%.8f,\"current_price\":%.8f,\"pips\":%.2f,\"floating_profit\":%.2f,\"status\":\"CLOSED\",\"opened_at\":\"%s\",\"closed_at\":\"%s\",\"close_reason\":\"%s\"}",
         ticket,
         JsonEscape(symbol),
         JsonEscape(side),
         volume,
         entry_price,
         close_price,
         pips,
         profit,
         TimeToString(
            opened_at,
            TIME_DATE|TIME_SECONDS
         ),
         TimeToString(
            closed_at,
            TIME_DATE|TIME_SECONDS
         ),
         JsonEscape(reason)
      );

   string response_text;
   int status;

   return
      HttpRequest(
         "POST",
         "/positions",
         body,
         response_text,
         status
      ) &&
      status >= 200 &&
      status < 300;
}

bool ClosePositionByTicket(
   ulong ticket,
   string reason
)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol =
      PositionGetString(
         POSITION_SYMBOL
      );

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(
         POSITION_TYPE
      );

   string side =
      (
         type == POSITION_TYPE_BUY
         ? "BUY"
         : "SELL"
      );

   double volume =
      PositionGetDouble(
         POSITION_VOLUME
      );

   double entry_price =
      PositionGetDouble(
         POSITION_PRICE_OPEN
      );

   double stop_loss =
      PositionGetDouble(
         POSITION_SL
      );

   double close_price =
      PositionGetDouble(
         POSITION_PRICE_CURRENT
      );

   double profit =
      PositionGetDouble(
         POSITION_PROFIT
      );

   datetime opened_at =
      (datetime)PositionGetInteger(
         POSITION_TIME
      );

   double pips =
      PositionPips(
         symbol,
         type,
         entry_price,
         close_price
      );

   if(!trade.PositionClose(ticket))
   {
      PrintFormat(
         "[%s] CLOSE failed ticket=%I64u retcode=%d %s",
         symbol,
         ticket,
         trade.ResultRetcode(),
         trade.ResultRetcodeDescription()
      );

      return false;
   }

   RememberBotClosed(ticket);

   datetime closed_at =
      TimeCurrent();

   string body =
      StringFormat(
         "{\"action\":\"CLOSE\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"side\":\"%s\",\"volume\":%.2f,\"price\":%.8f,\"profit\":%.2f,\"pips\":%.2f,\"reason\":\"%s\",\"execution_status\":\"SUCCESS\"}",
         JsonEscape(symbol),
         ticket,
         side,
         volume,
         close_price,
         profit,
         pips,
         JsonEscape(reason)
      );

   string response_text;
   int status;

   HttpRequest(
      "POST",
      "/execution",
      body,
      response_text,
      status
   );

   SendTransaction(
      ticket,
      symbol,
      side,
      volume,
      entry_price,
      stop_loss,
      close_price,
      pips,
      profit,
      reason,
      opened_at,
      closed_at
   );

   MarkPositionClosed(
      ticket,
      symbol,
      side,
      volume,
      entry_price,
      close_price,
      pips,
      profit,
      reason,
      opened_at,
      closed_at
   );

   PrintFormat(
      "[%s] Position closed ticket=%I64u pips=%.2f reason=%s",
      symbol,
      ticket,
      pips,
      reason
   );

   return true;
}

double NormalizeVolume(
   string symbol,
   double volume
)
{
   double minv =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxv =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_MAX
      );

   double step =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_STEP
      );

   if(step <= 0.0)
      step = minv;

   volume =
      MathMax(
         minv,
         MathMin(
            maxv,
            volume
         )
      );

   volume =
      MathFloor(
         volume / step
      ) * step;

   int digits = 2;

   if(step >= 1.0)
      digits = 0;
   else if(step >= 0.1)
      digits = 1;

   return NormalizeDouble(
      volume,
      digits
   );
}

double CalculateVolume(
   string symbol,
   string action,
   double stop_loss
)
{
   const double FIXED_VOLUME = 0.01;

   double minv =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_MIN
      );

   double maxv =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_MAX
      );

   double step =
      SymbolInfoDouble(
         symbol,
         SYMBOL_VOLUME_STEP
      );

   double free_margin =
      AccountInfoDouble(
         ACCOUNT_MARGIN_FREE
      );

   if(
      minv <= 0.0 ||
      maxv <= 0.0 ||
      step <= 0.0 ||
      free_margin <= 0.0
   )
   {
      return 0.0;
   }

   if(
      FIXED_VOLUME < minv ||
      FIXED_VOLUME > maxv
   )
   {
      PrintFormat(
         "[%s] Trade skipped: fixed volume %.2f is outside broker range %.2f - %.2f",
         symbol,
         FIXED_VOLUME,
         minv,
         maxv
      );

      return 0.0;
   }

   double step_units =
      FIXED_VOLUME / step;

   if(
      MathAbs(
         step_units -
         MathRound(step_units)
      ) > 0.0000001
   )
   {
      PrintFormat(
         "[%s] Trade skipped: fixed volume %.2f does not match broker volume step %.4f",
         symbol,
         FIXED_VOLUME,
         step
      );

      return 0.0;
   }

   MqlTick tick;

   if(!SymbolInfoTick(symbol, tick))
      return 0.0;

   double entry_price =
      (
         action == "BUY"
         ? tick.ask
         : tick.bid
      );

   if(entry_price <= 0.0)
      return 0.0;

   ENUM_ORDER_TYPE order_type =
      (
         action == "BUY"
         ? ORDER_TYPE_BUY
         : ORDER_TYPE_SELL
      );

   double usable_margin =
      free_margin * 0.90;

   double margin_required = 0.0;

   ResetLastError();

   if(!OrderCalcMargin(
         order_type,
         symbol,
         FIXED_VOLUME,
         entry_price,
         margin_required
      ))
   {
      PrintFormat(
         "[%s] Trade skipped: unable to calculate margin for fixed volume %.2f error=%d",
         symbol,
         FIXED_VOLUME,
         GetLastError()
      );

      return 0.0;
   }

   if(margin_required > usable_margin)
   {
      PrintFormat(
         "[%s] Trade skipped: fixed volume %.2f requires margin %.2f, usable free margin %.2f",
         symbol,
         FIXED_VOLUME,
         margin_required,
         usable_margin
      );

      return 0.0;
   }

   PrintFormat(
      "[%s] Fixed volume: action=%s volume=%.2f entry=%.5f margin=%.2f",
      symbol,
      action,
      FIXED_VOLUME,
      entry_price,
      margin_required
   );

   return FIXED_VOLUME;
}

double PrepareValidStopLoss(
   string symbol,
   string action,
   double requested_sl,
   double bid,
   double ask,
   bool &adjusted
)
{
   adjusted = false;

   double point =
      SymbolInfoDouble(
         symbol,
         SYMBOL_POINT
      );

   double tick_size =
      SymbolInfoDouble(
         symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   int digits =
      (int)SymbolInfoInteger(
         symbol,
         SYMBOL_DIGITS
      );

   long stops_level =
      SymbolInfoInteger(
         symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   long freeze_level =
      SymbolInfoInteger(
         symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   if(point <= 0.0)
      return requested_sl;

   if(tick_size <= 0.0)
      tick_size = point;

   double min_distance =
      (double)MathMax(
         stops_level,
         freeze_level
      ) * point + tick_size;

   double sl =
      requested_sl;

   if(action == "BUY")
   {
      double max_sl =
         bid - min_distance;

      if(
         sl <= 0.0 ||
         sl > max_sl
      )
      {
         sl = max_sl;
         adjusted = true;
      }
   }
   else if(action == "SELL")
   {
      double min_sl =
         ask + min_distance;

      if(
         sl <= 0.0 ||
         sl < min_sl
      )
      {
         sl = min_sl;
         adjusted = true;
      }
   }

   sl =
      MathRound(
         sl / tick_size
      ) * tick_size;

   sl =
      NormalizeDouble(
         sl,
         digits
      );

   if(adjusted)
   {
      PrintFormat(
         "[%s] SL adjusted: requested=%.5f final=%.5f stops_level=%d freeze_level=%d point=%.5f tick_size=%.5f",
         symbol,
         requested_sl,
         sl,
         (int)stops_level,
         (int)freeze_level,
         point,
         tick_size
      );
   }

   return sl;
}

double PrepareValidTakeProfit(
   string symbol,
   string action,
   double requested_tp,
   double bid,
   double ask,
   bool &adjusted
)
{
   adjusted = false;

   double point =
      SymbolInfoDouble(
         symbol,
         SYMBOL_POINT
      );

   double tick_size =
      SymbolInfoDouble(
         symbol,
         SYMBOL_TRADE_TICK_SIZE
      );

   int digits =
      (int)SymbolInfoInteger(
         symbol,
         SYMBOL_DIGITS
      );

   long stops_level =
      SymbolInfoInteger(
         symbol,
         SYMBOL_TRADE_STOPS_LEVEL
      );

   long freeze_level =
      SymbolInfoInteger(
         symbol,
         SYMBOL_TRADE_FREEZE_LEVEL
      );

   if(point <= 0.0)
      return requested_tp;

   if(tick_size <= 0.0)
      tick_size = point;

   double min_distance =
      (double)MathMax(
         stops_level,
         freeze_level
      ) * point + tick_size;

   double tp =
      requested_tp;

   if(action == "BUY")
   {
      double min_tp =
         ask + min_distance;

      if(
         tp <= 0.0 ||
         tp < min_tp
      )
      {
         tp = min_tp;
         adjusted = true;
      }
   }
   else if(action == "SELL")
   {
      double max_tp =
         bid - min_distance;

      if(
         tp <= 0.0 ||
         tp > max_tp
      )
      {
         tp = max_tp;
         adjusted = true;
      }
   }

   tp =
      MathRound(
         tp / tick_size
      ) * tick_size;

   tp =
      NormalizeDouble(
         tp,
         digits
      );

   if(adjusted)
   {
      PrintFormat(
         "[%s] TP adjusted: requested=%.5f final=%.5f stops_level=%d freeze_level=%d point=%.5f tick_size=%.5f",
         symbol,
         requested_tp,
         tp,
         (int)stops_level,
         (int)freeze_level,
         point,
         tick_size
      );
   }

   return tp;
}

string ExtractFirstSignal(string json)
{
   int a =
      StringFind(
         json,
         "\"signals\":["
      );

   if(a < 0)
      return "";

   a =
      StringFind(
         json,
         "{",
         a
      );

   if(a < 0)
      return "";

   int depth = 0;
   bool in_string = false;

   for(
      int i=a;
      i<StringLen(json);
      i++
   )
   {
      ushort ch =
         StringGetCharacter(
            json,
            i
         );

      if(
         ch == '"' &&
         (
            i == 0 ||
            StringGetCharacter(
               json,
               i-1
            ) != '\\'
         )
      )
      {
         in_string =
            !in_string;
      }

      if(in_string)
         continue;

      if(ch == '{')
         depth++;

      else if(ch == '}')
      {
         depth--;

         if(depth == 0)
         {
            return StringSubstr(
               json,
               a,
               i-a+1
            );
         }
      }
   }

   return "";
}

bool PollAndExecuteSignal()
{
   // =========================================================
   // 1. SAFETY / MODE CHECK
   // =========================================================

   if(!g_bot_enabled)
      return false;

   if(g_bot_mode != "AUTO")
      return false;

   if(!InpAllowTrading)
      return false;

   // =========================================================
   // 2. POLL SIGNAL TERBARU
   // =========================================================

   string json;
   int status = 0;

   string signal_path =
      "/signals?symbol=" +
      _Symbol +
      "&limit=1";

   if(!HttpRequest(
         "GET",
         signal_path,
         "",
         json,
         status
      ))
   {
      if(status > 0)
      {
         PrintFormat(
            "[%s] Signal poll HTTP %d response=%s",
            _Symbol,
            status,
            json
         );
      }

      return false;
   }

   if(status != 200)
   {
      PrintFormat(
         "[%s] Signal poll rejected HTTP=%d",
         _Symbol,
         status
      );

      return false;
   }

   // =========================================================
   // 3. EXTRACT SIGNAL
   // =========================================================

   string signal =
      ExtractFirstSignal(json);

   if(StringLen(signal) == 0)
   {
      // NONE tetap tidak ditampilkan, tetapi catat hasil polling agar
      // masalah delivery dapat dibedakan dari signal-engine generation.
      PrintFormat(
         "[%s] Signal poll OK: no actionable NEW signal returned.",
         _Symbol
      );
      return false;
   }

   // =========================================================
   // 4. PARSE SIGNAL
   // =========================================================

   string id =
      JsonString(
         signal,
         "id",
         ""
      );

   string symbol =
      JsonString(
         signal,
         "symbol",
         ""
      );

   string action =
      JsonString(
         signal,
         "signal",
         ""
      );

   string execution_action = action;
   if(action == "BUY")
      execution_action = "SELL";
   else if(action == "SELL")
      execution_action = "BUY";

   double stop_loss =
      JsonNumber(
         signal,
         "stop_loss",
         0.0
      );

   // =========================================================
   // 5. VALIDASI ID / SYMBOL
   // =========================================================

   if(
      StringLen(id) == 0 ||
      StringLen(symbol) == 0
   )
   {
      PrintFormat(
         "[%s] Signal received but id/symbol missing.",
         _Symbol
      );

      return false;
   }

   // =========================================================
   // 6. VALIDASI SYMBOL
   // =========================================================

   if(!IsManagedSymbol(symbol))
   {
      PrintFormat(
         "[%s] Signal ignored: unmanaged symbol=%s",
         _Symbol,
         symbol
      );

      return false;
   }

   // =========================================================
   // 7. SIGNAL CLOSE
   // =========================================================

   if(action == "CLOSE")
   {
      bool closed_any = false;

      for(
         int i=PositionsTotal()-1;
         i>=0;
         i--
      )
      {
         ulong ticket =
            PositionGetTicket(i);

         if(ticket == 0 ||
            !PositionSelectByTicket(ticket))
         {
            continue;
         }

         if(
            PositionGetString(
               POSITION_SYMBOL
            ) != symbol
         )
         {
            continue;
         }

         if(
            ClosePositionByTicket(
               ticket,
               "SIGNAL_CLOSE"
            )
         )
         {
            closed_any = true;
         }
      }

      string consume_body =
         StringFormat(
            "{\"id\":\"%s\",\"status\":\"CONSUMED\"}",
            JsonEscape(id)
         );

      string consume_response;
      int consume_status = 0;

      HttpRequest(
         "POST",
         "/signals/consume",
         consume_body,
         consume_response,
         consume_status
      );

      if(closed_any)
      {
         PrintFormat(
            "[%s] CLOSE signal executed id=%s",
            symbol,
            id
         );
      }
      else
      {
         PrintFormat(
            "[%s] CLOSE signal received but no matching open position id=%s",
            symbol,
            id
         );
      }

      return closed_any;
   }

   // =========================================================
   // 8. ONLY BUY / SELL
   // =========================================================

   if(
      action != "BUY" &&
      action != "SELL"
   )
   {
      PrintFormat(
         "[%s] Signal ignored: action=%s id=%s",
         symbol,
         action,
         id
      );

      return false;
   }

   PrintFormat(
      "[%s] Signal received id=%s action=%s",
      symbol,
      id,
      action
   );

   // =========================================================
   // 9. MAX POSITION
   // =========================================================

   int current_positions =
      OpenPositionCount();

   if(
      current_positions >=
      g_max_positions
   )
   {
      PrintFormat(
         "[%s] Signal held: open_positions=%d max_positions=%d",
         symbol,
         current_positions,
         g_max_positions
      );

      return false;
   }

   // =========================================================
   // 10. SELECT SYMBOL
   // =========================================================

   if(!SymbolSelect(symbol, true))
   {
      PrintFormat(
         "[%s] Signal rejected: SymbolSelect failed.",
         symbol
      );

      return false;
   }

   // =========================================================
   // 11. LIVE TICK
   // =========================================================

   MqlTick tick;

   if(!SymbolInfoTick(symbol, tick))
   {
      PrintFormat(
         "[%s] Signal rejected: SymbolInfoTick failed.",
         symbol
      );

      return false;
   }

   if(
      tick.ask <= 0.0 ||
      tick.bid <= 0.0
   )
   {
      PrintFormat(
         "[%s] Signal rejected: invalid tick bid=%.5f ask=%.5f",
         symbol,
         tick.bid,
         tick.ask
      );

      return false;
   }

   // =========================================================
   // 12. PIP SIZE
   // =========================================================

   double pip_size =
      PipSize(symbol);

   if(pip_size <= 0.0)
   {
      PrintFormat(
         "[%s] Signal rejected: invalid pip_size=%.10f",
         symbol,
         pip_size
      );

      return false;
   }

   // =========================================================
   // 13. LIVE ENTRY PRICE
   // =========================================================

   double execution_price =
      (
         execution_action == "BUY"
         ? tick.ask
         : tick.bid
      );

   // =========================================================
   // 14. TARGET LOSS
   //
   // Dashboard:
   // Target Loss = 100 pip
   // =========================================================

   double target_sl =
      stop_loss;

   if(g_target_loss_pips > 0.0)
   {
      if(execution_action == "BUY")
      {
         target_sl =
            execution_price -
            (
               g_target_loss_pips *
               pip_size
            );
      }
      else
      {
         target_sl =
            execution_price +
            (
               g_target_loss_pips *
               pip_size
            );
      }
   }

   bool sl_adjusted = false;

   double valid_stop_loss =
      PrepareValidStopLoss(
         symbol,
         execution_action,
         target_sl,
         tick.bid,
         tick.ask,
         sl_adjusted
      );

   // =========================================================
   // 15. TARGET PROFIT
   //
   // Dashboard:
   // Target Profit = 50 pip
   // =========================================================

   double target_tp = 0.0;

   if(g_target_profit_pips > 0.0)
   {
      if(execution_action == "BUY")
      {
         target_tp =
            execution_price +
            (
               g_target_profit_pips *
               pip_size
            );
      }
      else
      {
         target_tp =
            execution_price -
            (
               g_target_profit_pips *
               pip_size
            );
      }
   }

   bool tp_adjusted = false;

   double valid_take_profit =
      PrepareValidTakeProfit(
         symbol,
         execution_action,
         target_tp,
         tick.bid,
         tick.ask,
         tp_adjusted
      );

   // =========================================================
   // 16. CALCULATE LOT
   // =========================================================

   double volume =
      CalculateVolume(
         symbol,
         execution_action,
         valid_stop_loss
      );

   if(volume <= 0.0)
   {
      PrintFormat(
         "[%s] Signal rejected: calculated volume=%.4f",
         symbol,
         volume
      );

      return false;
   }

   // =========================================================
   // 17. DIAGNOSTIC SEBELUM ORDER
   // =========================================================

   PrintFormat(
      "[%s] Preparing signal=%s execution=%s volume=%.2f entry=%.5f SL=%.5f TP=%.5f target_profit=%.2f pip target_loss=%.2f pip",
      symbol,
      action,
      execution_action,
      volume,
      execution_price,
      valid_stop_loss,
      valid_take_profit,
      g_target_profit_pips,
      g_target_loss_pips
   );

   // =========================================================
   // 18. EXISTING MT5 EXECUTION
   //
   // Execute inverse side; original signal remains in the audit payload.
   // =========================================================

   bool ok = false;

   trade.SetExpertMagicNumber(260928);

   trade.SetTypeFillingBySymbol(symbol);

   if(execution_action == "BUY")
   {
      ok =
         trade.Buy(
            volume,
            symbol,
            0.0,
            valid_stop_loss,
            valid_take_profit,
            "KBPARI:" + id
         );
   }
   else
   {
      ok =
         trade.Sell(
            volume,
            symbol,
            0.0,
            valid_stop_loss,
            valid_take_profit,
            "KBPARI:" + id
         );
   }

   // =========================================================
   // 19. ORDER REJECTED
   // =========================================================

   if(!ok)
   {
      PrintFormat(
         "[%s] %s rejected retcode=%d %s",
         symbol,
         action,
         trade.ResultRetcode(),
         trade.ResultRetcodeDescription()
      );

      string reject =
         StringFormat(
            "{\"id\":\"%s\",\"status\":\"REJECTED\"}",
            JsonEscape(id)
         );

      string reject_response;
      int reject_status = 0;

      HttpRequest(
         "POST",
         "/signals/consume",
         reject,
         reject_response,
         reject_status
      );

      return false;
   }

   // =========================================================
   // 20. ORDER SUCCESS
   // =========================================================

   ulong order_ticket =
      trade.ResultOrder();

   ulong deal_ticket =
      trade.ResultDeal();

   ulong position_ticket = 0;

   if(deal_ticket > 0)
   {
      position_ticket =
         (ulong)HistoryDealGetInteger(
            deal_ticket,
            DEAL_POSITION_ID
         );
   }

   if(
      position_ticket == 0 &&
      PositionSelect(symbol)
   )
   {
      position_ticket =
         (ulong)PositionGetInteger(
            POSITION_TICKET
         );
   }

   double fill_price =
      trade.ResultPrice();

   // =========================================================
   // 21. POST ORDER
   // =========================================================

   string order_body =
      StringFormat(
         "{\"client_order_id\":\"%s\",\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"requested_price\":%.8f,\"stop_loss\":%.8f,\"take_profit\":%.8f,\"status\":\"FILLED\",\"signal_id\":\"%s\"}",
         "KBPARI-" + id,
         order_ticket,
         JsonEscape(symbol),
         execution_action,
         volume,
         fill_price,
         valid_stop_loss,
         valid_take_profit,
         JsonEscape(id)
      );

   string order_response;
   int order_status = 0;

   HttpRequest(
      "POST",
      "/orders",
      order_body,
      order_response,
      order_status
   );

   // =========================================================
   // 22. CONSUME SIGNAL
   // =========================================================

   string consume_body =
      StringFormat(
         "{\"id\":\"%s\",\"status\":\"CONSUMED\"}",
         JsonEscape(id)
      );

   string consume_response;
   int consume_status = 0;

   HttpRequest(
      "POST",
      "/signals/consume",
      consume_body,
      consume_response,
      consume_status
   );

   // =========================================================
   // 23. EXECUTION AUDIT
   // =========================================================

   string exec_body =
      StringFormat(
         "{\"action\":\"OPEN\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"side\":\"%s\",\"volume\":%.2f,\"price\":%.8f,\"reason\":\"SIGNAL:%s\",\"execution_status\":\"SUCCESS\"}",
         JsonEscape(symbol),
         position_ticket,
         execution_action,
         volume,
         fill_price,
         JsonEscape(id)
      );

   string exec_response;
   int exec_status = 0;

   HttpRequest(
      "POST",
      "/execution",
      exec_body,
      exec_response,
      exec_status
   );

   // =========================================================
   // 24. FINAL SUCCESS LOG
   // =========================================================

   PrintFormat(
      "[%s] %s executed order=%I64u position=%I64u volume=%.2f entry=%.5f SL=%.5f TP=%.5f target_profit=%.2f pip target_loss=%.2f pip%s%s",
      symbol,
      action,
      order_ticket,
      position_ticket,
      volume,
      fill_price,
      valid_stop_loss,
      valid_take_profit,
      g_target_profit_pips,
      g_target_loss_pips,
      sl_adjusted ? " SL-adjusted" : "",
      tp_adjusted ? " TP-adjusted" : ""
   );

   return true;
}

void ManagePositions()
{
   if(
      g_target_profit_pips <= 0.0 &&
      g_target_loss_pips <= 0.0
   )
   {
      return;
   }

   for(
      int i=PositionsTotal()-1;
      i>=0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket)
      )
      {
         continue;
      }

      string symbol =
         PositionGetString(
            POSITION_SYMBOL
         );

      if(!IsManagedSymbol(symbol))
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)
         PositionGetInteger(
            POSITION_TYPE
         );

      double pips =
         PositionPips(
            symbol,
            type,
            PositionGetDouble(
               POSITION_PRICE_OPEN
            ),
            PositionGetDouble(
               POSITION_PRICE_CURRENT
            )
         );

      if(
         g_target_profit_pips > 0.0 &&
         pips >= g_target_profit_pips
      )
      {
         ClosePositionByTicket(
            ticket,
            "TARGET_PROFIT_PIPS"
         );

         continue;
      }

      if(
         g_target_loss_pips > 0.0 &&
         pips <= -g_target_loss_pips
      )
      {
         ClosePositionByTicket(
            ticket,
            "TARGET_LOSS_PIPS"
         );

         continue;
      }

      SendPositionSnapshot(ticket);
   }
}

void SyncOpenPositions()
{
   for(
      int i=PositionsTotal()-1;
      i>=0;
      i--
   )
   {
      ulong ticket =
         PositionGetTicket(i);

      if(
         ticket == 0 ||
         !PositionSelectByTicket(ticket)
      )
      {
         continue;
      }

      if(
         !IsManagedSymbol(
            PositionGetString(
               POSITION_SYMBOL
            )
         )
      )
      {
         continue;
      }

      SendPositionSnapshot(ticket);
   }
}

void CheckForManualCloses()
{
   static ulong known_tickets[];

   ulong current[];

   ArrayResize(
      current,
      PositionsTotal()
   );

   for(
      int i=0;
      i<PositionsTotal();
      i++
   )
   {
      current[i] =
         PositionGetTicket(i);
   }

   for(
      int k=0;
      k<ArraySize(known_tickets);
      k++
   )
   {
      ulong old_ticket =
         known_tickets[k];

      bool still_open = false;

      for(
         int j=0;
         j<ArraySize(current);
         j++
      )
      {
         if(current[j] == old_ticket)
         {
            still_open = true;
            break;
         }
      }

      if(!still_open)
      {
         if(WasBotClosed(old_ticket))
         {
            ForgetBotClosed(old_ticket);
            continue;
         }

         HistorySelect(
            TimeCurrent()-86400,
            TimeCurrent()
         );

         if(HistorySelectByPosition(old_ticket))
         {
            double profit = 0.0;
            double volume = 0.0;
            double entry_price = 0.0;
            double stop_loss = 0.0;
            double close_price = 0.0;
            double pips = 0.0;

            datetime opened_at = 0;
            datetime close_time = 0;

            ENUM_POSITION_TYPE position_type =
               POSITION_TYPE_BUY;

            string symbol = "";

            int deals =
               HistoryDealsTotal();

            for(
               int d=0;
               d<deals;
               d++
            )
            {
               ulong deal =
                  HistoryDealGetTicket(d);

               if(deal == 0)
                  continue;

               if(
                  (ulong)HistoryDealGetInteger(
                     deal,
                     DEAL_POSITION_ID
                  ) != old_ticket
               )
               {
                  continue;
               }

               string deal_symbol =
                  HistoryDealGetString(
                     deal,
                     DEAL_SYMBOL
                  );

               if(StringLen(symbol) == 0)
                  symbol = deal_symbol;

               long entry =
                  HistoryDealGetInteger(
                     deal,
                     DEAL_ENTRY
                  );

               long deal_type =
                  HistoryDealGetInteger(
                     deal,
                     DEAL_TYPE
                  );

               if(
                  entry == DEAL_ENTRY_IN ||
                  entry == DEAL_ENTRY_INOUT
               )
               {
                  entry_price =
                     HistoryDealGetDouble(
                        deal,
                        DEAL_PRICE
                     );

                  stop_loss =
                     HistoryDealGetDouble(
                        deal,
                        DEAL_SL
                     );

                  volume +=
                     HistoryDealGetDouble(
                        deal,
                        DEAL_VOLUME
                     );

                  opened_at =
                     (datetime)
                     HistoryDealGetInteger(
                        deal,
                        DEAL_TIME
                     );

                  position_type =
                     (
                        deal_type == DEAL_TYPE_SELL
                        ? POSITION_TYPE_SELL
                        : POSITION_TYPE_BUY
                     );
               }

               if(
                  entry == DEAL_ENTRY_OUT ||
                  entry == DEAL_ENTRY_OUT_BY ||
                  entry == DEAL_ENTRY_INOUT
               )
               {
                  close_price =
                     HistoryDealGetDouble(
                        deal,
                        DEAL_PRICE
                     );

                  profit +=
                     HistoryDealGetDouble(
                        deal,
                        DEAL_PROFIT
                     );

                  close_time =
                     (datetime)
                     HistoryDealGetInteger(
                        deal,
                        DEAL_TIME
                     );
               }
            }

            if(
               StringLen(symbol) > 0 &&
               entry_price > 0.0 &&
               close_price > 0.0 &&
               IsManagedSymbol(symbol)
            )
            {
               pips =
                  PositionPips(
                     symbol,
                     position_type,
                     entry_price,
                     close_price
                  );

               string body =
                  StringFormat(
                     "{\"action\":\"CLOSE\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"side\":\"%s\",\"volume\":%.2f,\"price\":%.8f,\"profit\":%.2f,\"pips\":%.2f,\"reason\":\"MANUAL_OR_EXTERNAL_CLOSE\",\"execution_status\":\"SUCCESS\",\"executed_at\":\"%s\"}",
                     JsonEscape(symbol),
                     old_ticket,
                     position_type == POSITION_TYPE_BUY
                        ? "BUY"
                        : "SELL",
                     volume,
                     close_price,
                     profit,
                     pips,
                     TimeToString(
                        close_time,
                        TIME_DATE|TIME_SECONDS
                     )
                  );

               string response_text;
               int status;

               HttpRequest(
                  "POST",
                  "/execution",
                  body,
                  response_text,
                  status
               );

               SendTransaction(
                  old_ticket,
                  symbol,
                  position_type == POSITION_TYPE_BUY
                     ? "BUY"
                     : "SELL",
                  volume,
                  entry_price,
                  stop_loss,
                  close_price,
                  pips,
                  profit,
                  "MANUAL_OR_EXTERNAL_CLOSE",
                  opened_at,
                  close_time
               );

               MarkPositionClosed(
                  old_ticket,
                  symbol,
                  position_type == POSITION_TYPE_BUY
                     ? "BUY"
                     : "SELL",
                  volume,
                  entry_price,
                  close_price,
                  pips,
                  profit,
                  "MANUAL_OR_EXTERNAL_CLOSE",
                  opened_at,
                  close_time
               );
            }
         }
      }
   }

   ArrayResize(
      known_tickets,
      ArraySize(current)
   );

   for(
      int i=0;
      i<ArraySize(current);
      i++
   )
   {
      known_tickets[i] =
         current[i];
   }
}

// ============================================================
// EA TIMER 1.040
//
// URUTAN BARU:
//
// 1. Refresh config
// 2. Send heartbeat
// 3. Send market data
// 4. Check manual closes
// 5. Manage positions
// 6. Poll signal
// 7. Execute signal
//
// Dengan demikian signal yang baru dibuat Worker dari
// /market-data dapat langsung dipoll pada timer yang sama.
// ============================================================

void OnTimer()
{
   datetime now =
      TimeCurrent();

   // ---------------------------------------------------------
   // 1. Refresh configuration
   // ---------------------------------------------------------

   if(
      g_last_config_fetch == 0 ||
      (
         now - g_last_config_fetch
      ) >= InpConfigRefreshSeconds
   )
   {
      RefreshConfig();
   }

   // ---------------------------------------------------------
   // 2. Market-data synchronization
   // ---------------------------------------------------------

   if(
      g_last_sync == 0 ||
      (
         now - g_last_sync
      ) >= 10
   )
   {
      SendHeartbeat();

      // IMPORTANT:
      // Market data dikirim sebelum polling signal.
      SendMarketData();

      CheckForManualCloses();

      g_last_sync = now;
   }

   // ---------------------------------------------------------
   // 3. Automatic trading
   // ---------------------------------------------------------

   if(
      g_bot_enabled &&
      g_bot_mode == "AUTO" &&
      InpAllowTrading
   )
   {
      // Kelola posisi yang sudah terbuka terlebih dahulu.
      ManagePositions();

      // Setelah market-data dikirim,
      // ambil signal terbaru dari Worker.
      PollAndExecuteSignal();
   }
   else
   {
      SyncOpenPositions();
   }
}

int OnInit()
{
   g_worker_url =
      InpWorkerURL;

   while(
      StringLen(g_worker_url) > 0 &&
      StringSubstr(
         g_worker_url,
         StringLen(g_worker_url)-1,
         1
      ) == "/"
   )
   {
      g_worker_url =
         StringSubstr(
            g_worker_url,
            0,
            StringLen(g_worker_url)-1
         );
   }

   g_api_key =
      InpBotAPIKey;

   if(StringLen(g_worker_url) < 8)
   {
      Print(
         "[KBPARI] WARNING: Worker URL is not configured."
      );
   }

   if(StringLen(g_api_key) == 0)
   {
      Print(
         "[KBPARI] WARNING: Bot API key is not configured."
      );
   }

   EventSetTimer(
      MathMax(
         1,
         InpTimerSeconds
      )
   );

   RefreshConfig();

   Print(
      "[KBPARI] MT5 EA 1.041 initialized. Inverse execution ON: BUY->SELL, SELL->BUY."
   );

   PrintFormat(
      "[KBPARI] Signal engine market-data feed enabled for chart symbol %s only.",
      _Symbol
   );

   Print(
      "[KBPARI] Target Profit and Target Loss are dynamic Worker/Supabase values."
   );

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTick()
{
   // Timer-driven architecture prevents repeated actions
   // on every market tick.
}

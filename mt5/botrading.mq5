#property strict
#property version   "1.011"
#property description "KBPARI MT5 Expert Advisor - dynamic configuration from Worker/Supabase"

#include <Trade/Trade.mqh>

CTrade trade;

input string InpWorkerURL = "https://kbpari.pbahagia433.workers.dev";
input string InpBotAPIKey = "";
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
   StringReplace(value, "\\", "\\\\");
   StringReplace(value, """, "\\"");
   StringReplace(value, "\r", "\\r");
   StringReplace(value, "\n", "\\n");
   return value;
}

bool HttpRequest(string method, string path, string body, string &response_text, int &status_code)
{
   response_text = "";
   status_code = 0;

   if(StringLen(g_worker_url) < 8 || StringLen(g_api_key) == 0)
      return false;

   string url = g_worker_url + path;
   string headers = "Content-Type: application/json\r\nX-Bot-Key: " + g_api_key + "\r\n";
   char data[];
   char result[];
   string result_headers = "";

   if(StringLen(body) > 0)
      StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   else
      ArrayResize(data, 0);

   ResetLastError();
   status_code = WebRequest(method, url, headers, InpHttpTimeoutMs, data, result, result_headers);
   if(status_code < 0)
   {
      PrintFormat("[KBPARI] WebRequest failed path=%s error=%d", path, GetLastError());
      return false;
   }

   response_text = CharArrayToString(result, 0, -1, CP_UTF8);
   return true;
}

string JsonString(string json, string key, string fallback="")
{
   string needle = """ + key + "":";
   int p = StringFind(json, needle);
   if(p < 0) return fallback;
   p += StringLen(needle);
   while(p < StringLen(json) && (StringGetCharacter(json,p)==' ' || StringGetCharacter(json,p)=='\t')) p++;
   if(p >= StringLen(json) || StringGetCharacter(json,p) != '"') return fallback;
   p++;
   int e = p;
   while(e < StringLen(json))
   {
      if(StringGetCharacter(json,e)=='"' && (e==p || StringGetCharacter(json,e-1)!='\\')) break;
      e++;
   }
   if(e >= StringLen(json)) return fallback;
   return StringSubstr(json,p,e-p);
}

double JsonNumber(string json, string key, double fallback=0.0)
{
   string needle = """ + key + "":";
   int p = StringFind(json, needle);
   if(p < 0) return fallback;
   p += StringLen(needle);
   while(p < StringLen(json) && (StringGetCharacter(json,p)==' ' || StringGetCharacter(json,p)=='\t')) p++;
   int e = p;
   while(e < StringLen(json))
   {
      ushort c = StringGetCharacter(json,e);
      if((c>='0' && c<='9') || c=='-' || c=='+' || c=='.' || c=='e' || c=='E') e++;
      else break;
   }
   if(e <= p) return fallback;
   return StringToDouble(StringSubstr(json,p,e-p));
}

bool JsonBool(string json, string key, bool fallback=false)
{
   string needle = """ + key + "":";
   int p = StringFind(json, needle);
   if(p < 0) return fallback;
   p += StringLen(needle);
   while(p < StringLen(json) && (StringGetCharacter(json,p)==' ' || StringGetCharacter(json,p)=='\t')) p++;
   if(StringSubstr(json,p,4)=="true") return true;
   if(StringSubstr(json,p,5)=="false") return false;
   return fallback;
}

double PipSize(string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

double PositionPips(string symbol, ENUM_POSITION_TYPE type, double open_price, double current_price)
{
   double pip = PipSize(symbol);
   if(pip <= 0.0) return 0.0;

   if(type == POSITION_TYPE_BUY)
      return (current_price - open_price) / pip;

   return (open_price - current_price) / pip;
}

int OpenPositionCount()
{
   int count = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
         count++;
   }
   return count;
}

bool IsManagedSymbol(string symbol)
{
   if(ArraySize(g_symbols) == 0)
      return symbol == "XAUUSD" || symbol == "EURUSD" || symbol == "GBPUSD";

   for(int i=0; i<ArraySize(g_symbols); i++)
      if(g_symbols[i] == symbol) return true;

   return false;
}

void ParseSymbols(string json)
{
   ArrayResize(g_symbols, 0);
   int p = StringFind(json, ""symbols":[");
   if(p < 0) return;
   p += StringLen(""symbols":[");
   int end = StringFind(json, "]", p);
   if(end < 0) return;

   string section = StringSubstr(json, p, end-p);
   int cursor = 0;
   while(cursor < StringLen(section))
   {
      int q1 = StringFind(section, """, cursor);
      if(q1 < 0) break;
      int q2 = StringFind(section, """, q1+1);
      if(q2 < 0) break;
      string symbol = StringSubstr(section, q1+1, q2-q1-1);
      if(StringLen(symbol) > 0)
      {
         int n = ArraySize(g_symbols);
         ArrayResize(g_symbols, n+1);
         g_symbols[n] = symbol;
      }
      cursor = q2 + 1;
   }
}

bool RefreshConfig()
{
   string body;
   int status;
   if(!HttpRequest("GET", "/config", "", body, status))
      return false;

   if(status != 200)
   {
      PrintFormat("[KBPARI] Config HTTP %d", status);
      return false;
   }

   int config_pos = StringFind(body, ""config":");
   if(config_pos < 0)
   {
      Print("[KBPARI] Invalid config response");
      return false;
   }

   g_bot_enabled = JsonBool(body, "enabled", false);
   g_bot_mode = JsonString(body, "mode", "PAUSED");
   g_target_profit_pips = JsonNumber(body, "target_profit_pips", 0.0);
   g_target_loss_pips = JsonNumber(body, "target_loss_pips", g_target_profit_pips * 2.0);
   g_risk_percent = JsonNumber(body, "risk_percent", 0.25);
   g_max_positions = (int)JsonNumber(body, "max_positions", 3.0);
   ParseSymbols(body);

   g_last_config_fetch = TimeCurrent();

   PrintFormat("[KBPARI] Config synced: enabled=%s mode=%s target_profit=%.2f pip target_loss=%.2f pip max_positions=%d",
               g_bot_enabled ? "true" : "false",
               g_bot_mode,
               g_target_profit_pips,
               g_target_loss_pips,
               g_max_positions);

   return true;
}

void SendHeartbeat()
{
   string body = StringFormat(
      "{\"bot_id\":\"%s\",\"ea_version\":\"%s\",\"mt5_account\":%I64d,\"balance\":%.2f,\"equity\":%.2f,\"free_margin\":%.2f,\"margin_level\":%.2f,\"terminal_time\":\"%s\",\"status\":\"ONLINE\",\"metadata\":{\"symbol\":\"%s\",\"chart_period\":%d}}",
      JsonEscape(InpBotID),
      "1.011",
      AccountInfoInteger(ACCOUNT_LOGIN),
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_MARGIN_FREE),
      AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      JsonEscape(_Symbol),
      Period());

   string response_text;
   int status;
   HttpRequest("POST", "/heartbeat", body, response_text, status);
}

bool SendPositionSnapshot(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
   double profit = PositionGetDouble(POSITION_PROFIT);
   double pips = PositionPips(symbol, type, open_price, current_price);

   string side = (type == POSITION_TYPE_BUY ? "BUY" : "SELL");
   string body = StringFormat(
      "{\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"entry_price\":%.8f,\"current_price\":%.8f,\"stop_loss\":%.8f,\"take_profit\":%.8f,\"pip_value\":%.8f,\"pips\":%.2f,\"floating_profit\":%.2f,\"status\":\"OPEN\",\"opened_at\":\"%s\"}",
      ticket, JsonEscape(symbol), side, volume, open_price, current_price,
      PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP),
      PipSize(symbol), pips, profit,
      TimeToString((datetime)PositionGetInteger(POSITION_TIME), TIME_DATE|TIME_SECONDS));

   string response_text;
   int status;
   return HttpRequest("POST", "/positions", body, response_text, status) && status >= 200 && status < 300;
}

bool SendTransaction(ulong ticket, string symbol, string side, double volume, double entry_price, double close_price, double pips, double profit, string reason, datetime opened_at, datetime closed_at)
{
   string body = StringFormat(
      "{\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"entry_price\":%.8f,\"close_price\":%.8f,\"pips\":%.2f,\"profit\":%.2f,\"close_reason\":\"%s\",\"opened_at\":\"%s\",\"closed_at\":\"%s\"}",
      ticket, JsonEscape(symbol), side, volume, entry_price, close_price, pips, profit,
      JsonEscape(reason),
      TimeToString(opened_at, TIME_DATE|TIME_SECONDS),
      TimeToString(closed_at, TIME_DATE|TIME_SECONDS));

   string response_text;
   int status;
   return HttpRequest("POST", "/transactions", body, response_text, status) && status >= 200 && status < 300;
}

bool MarkPositionClosed(ulong ticket, string symbol, string side, double volume, double entry_price, double close_price, double pips, double profit, string reason, datetime opened_at, datetime closed_at)
{
   string body = StringFormat(
      "{\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"entry_price\":%.8f,\"current_price\":%.8f,\"pips\":%.2f,\"floating_profit\":%.2f,\"status\":\"CLOSED\",\"opened_at\":\"%s\",\"closed_at\":\"%s\",\"close_reason\":\"%s\"}",
      ticket, JsonEscape(symbol), side, volume, entry_price, close_price, pips, profit,
      TimeToString(opened_at, TIME_DATE|TIME_SECONDS),
      TimeToString(closed_at, TIME_DATE|TIME_SECONDS),
      JsonEscape(reason));

   string response_text;
   int status;
   return HttpRequest("POST", "/positions", body, response_text, status) && status >= 200 && status < 300;
}

bool ClosePositionByTicket(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   string side = (type == POSITION_TYPE_BUY ? "BUY" : "SELL");
   double volume = PositionGetDouble(POSITION_VOLUME);
   double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double close_price = PositionGetDouble(POSITION_PRICE_CURRENT);
   double profit = PositionGetDouble(POSITION_PROFIT);
   datetime opened_at = (datetime)PositionGetInteger(POSITION_TIME);
   double pips = PositionPips(symbol, type, entry_price, close_price);

   if(!trade.PositionClose(ticket))
   {
      PrintFormat("[%s] CLOSE failed ticket=%I64u retcode=%d %s",
                  symbol, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }

   datetime closed_at = TimeCurrent();
   string body = StringFormat(
      "{\"action\":\"CLOSE\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"side\":\"%s\",\"volume\":%.2f,\"price\":%.8f,\"profit\":%.2f,\"pips\":%.2f,\"reason\":\"%s\",\"execution_status\":\"SUCCESS\"}",
      JsonEscape(symbol), ticket, side, volume, close_price, profit, pips, JsonEscape(reason));

   string response_text;
   int status;
   HttpRequest("POST", "/execution", body, response_text, status);
   SendTransaction(ticket, symbol, side, volume, entry_price, close_price, pips, profit, reason, opened_at, closed_at);
   MarkPositionClosed(ticket, symbol, side, volume, entry_price, close_price, pips, profit, reason, opened_at, closed_at);

   PrintFormat("[%s] Position closed ticket=%I64u pips=%.2f reason=%s", symbol, ticket, pips, reason);
   return true;
}


double NormalizeVolume(string symbol, double volume)
{
   double minv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = minv;
   volume = MathMax(minv, MathMin(maxv, volume));
   volume = MathFloor(volume / step) * step;
   int digits = 2;
   if(step >= 1.0) digits = 0;
   else if(step >= 0.1) digits = 1;
   return NormalizeDouble(volume, digits);
}

double CalculateVolume(string symbol, double stop_loss)
{
   double minv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = balance * MathMax(0.01, g_risk_percent) / 100.0;

   if(stop_loss <= 0.0)
      return minv;

   double price = SymbolInfoDouble(symbol, SYMBOL_BID);
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double distance = MathAbs(price - stop_loss);

   if(tick_size <= 0.0 || tick_value <= 0.0 || distance <= 0.0)
      return minv;

   double loss_per_lot = (distance / tick_size) * tick_value;
   if(loss_per_lot <= 0.0)
      return minv;

   return NormalizeVolume(symbol, risk_money / loss_per_lot);
}

string ExtractFirstSignal(string json)
{
   int a = StringFind(json, "\"signals\":[");
   if(a < 0) return "";
   a = StringFind(json, "{", a);
   if(a < 0) return "";

   int depth = 0;
   bool in_string = false;
   for(int i=a; i<StringLen(json); i++)
   {
      ushort ch = StringGetCharacter(json, i);
      if(ch == '"' && (i == 0 || StringGetCharacter(json, i-1) != '\\'))
         in_string = !in_string;
      if(in_string) continue;

      if(ch == '{') depth++;
      else if(ch == '}')
      {
         depth--;
         if(depth == 0)
            return StringSubstr(json, a, i-a+1);
      }
   }
   return "";
}

bool PollAndExecuteSignal()
{
   if(!g_bot_enabled || g_bot_mode != "AUTO" || !InpAllowTrading)
      return false;

   if(OpenPositionCount() >= g_max_positions)
      return false;

   string json;
   int status;
   if(!HttpRequest("GET", "/signals?limit=1", "", json, status) || status != 200)
      return false;

   string signal = ExtractFirstSignal(json);
   if(StringLen(signal) == 0)
      return false;

   string id = JsonString(signal, "id", "");
   string symbol = JsonString(signal, "symbol", "");
   string action = JsonString(signal, "signal", "");
   double stop_loss = JsonNumber(signal, "stop_loss", 0.0);

   if(StringLen(id) == 0 || StringLen(symbol) == 0)
      return false;

   if(!IsManagedSymbol(symbol))
      return false;

   if(action == "CLOSE")
   {
      bool closed_any = false;
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

         if(ClosePositionByTicket(ticket, "SIGNAL_CLOSE"))
            closed_any = true;
      }

      string consume_body = StringFormat("{\"id\":\"%s\",\"status\":\"CONSUMED\"}", JsonEscape(id));
      string consume_response;
      int consume_status;
      HttpRequest("POST", "/signals/consume", consume_body, consume_response, consume_status);
      return closed_any;
   }

   if(action != "BUY" && action != "SELL")
      return false;

   if(!SymbolSelect(symbol, true))
      return false;

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   double volume = CalculateVolume(symbol, stop_loss);
   if(volume <= 0.0)
      return false;

   bool ok = false;
   trade.SetExpertMagicNumber(260928);
   trade.SetTypeFillingBySymbol(symbol);

   if(action == "BUY")
      ok = trade.Buy(volume, symbol, 0.0, stop_loss, 0.0, "KBPARI:" + id);
   else
      ok = trade.Sell(volume, symbol, 0.0, stop_loss, 0.0, "KBPARI:" + id);

   if(!ok)
   {
      PrintFormat("[%s] %s failed retcode=%d %s", symbol, action, trade.ResultRetcode(), trade.ResultRetcodeDescription());

      string reject = StringFormat("{\"id\":\"%s\",\"status\":\"REJECTED\"}", JsonEscape(id));
      string reject_response;
      int reject_status;
      HttpRequest("POST", "/signals/consume", reject, reject_response, reject_status);
      return false;
   }

   ulong order_ticket = trade.ResultOrder();
   ulong deal_ticket = trade.ResultDeal();
   ulong position_ticket = 0;
   if(deal_ticket > 0)
      position_ticket = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
   if(position_ticket == 0 && PositionSelect(symbol))
      position_ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   double fill_price = trade.ResultPrice();

   string order_body = StringFormat(
      "{\"client_order_id\":\"%s\",\"mt5_ticket\":%I64u,\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"requested_price\":%.8f,\"stop_loss\":%.8f,\"take_profit\":null,\"status\":\"FILLED\",\"signal_id\":\"%s\"}",
      "KBPARI-" + id, order_ticket, JsonEscape(symbol), action, volume, fill_price, stop_loss, JsonEscape(id));

   string order_response;
   int order_status;
   HttpRequest("POST", "/orders", order_body, order_response, order_status);

   string consume_body = StringFormat("{\"id\":\"%s\",\"status\":\"CONSUMED\"}", JsonEscape(id));
   string consume_response;
   int consume_status;
   HttpRequest("POST", "/signals/consume", consume_body, consume_response, consume_status);

   string exec_body = StringFormat(
      "{\"action\":\"OPEN\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"side\":\"%s\",\"volume\":%.2f,\"price\":%.8f,\"reason\":\"SIGNAL:%s\",\"execution_status\":\"SUCCESS\"}",
      JsonEscape(symbol), position_ticket, action, volume, fill_price, JsonEscape(id));

   string exec_response;
   int exec_status;
   HttpRequest("POST", "/execution", exec_body, exec_response, exec_status);

   PrintFormat("[%s] %s executed order=%I64u position=%I64u volume=%.2f", symbol, action, order_ticket, position_ticket, volume);
   return true;
}

void ManagePositions()
{
   if(g_target_profit_pips <= 0.0 && g_target_loss_pips <= 0.0) return;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      if(!IsManagedSymbol(symbol)) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double pips = PositionPips(symbol, type,
                                 PositionGetDouble(POSITION_PRICE_OPEN),
                                 PositionGetDouble(POSITION_PRICE_CURRENT));

      if(g_target_profit_pips > 0.0 && pips >= g_target_profit_pips)
      {
         ClosePositionByTicket(ticket, "TARGET_PROFIT_PIPS");
         continue;
      }

      if(g_target_loss_pips > 0.0 && pips <= -g_target_loss_pips)
      {
         ClosePositionByTicket(ticket, "TARGET_LOSS_PIPS");
         continue;
      }

      SendPositionSnapshot(ticket);
   }
}

void SyncOpenPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
         SendPositionSnapshot(ticket);
   }
}

void CheckForManualCloses()
{
   static ulong known_tickets[];
   ulong current[];
   ArrayResize(current, PositionsTotal());

   for(int i=0; i<PositionsTotal(); i++)
      current[i] = PositionGetTicket(i);

   for(int k=0; k<ArraySize(known_tickets); k++)
   {
      ulong old_ticket = known_tickets[k];
      bool still_open = false;
      for(int j=0; j<ArraySize(current); j++)
      {
         if(current[j] == old_ticket)
         {
            still_open = true;
            break;
         }
      }

      if(!still_open)
      {
         HistorySelect(TimeCurrent()-86400, TimeCurrent());
         if(HistorySelectByPosition(old_ticket))
         {
            double profit = 0.0;
            double volume = 0.0;
            double entry_price = 0.0;
            double close_price = 0.0;
            double pips = 0.0;
            datetime opened_at = 0;
            datetime close_time = 0;
            ENUM_POSITION_TYPE position_type = POSITION_TYPE_BUY;
            string symbol = "";

            int deals = HistoryDealsTotal();
            for(int d=0; d<deals; d++)
            {
               ulong deal = HistoryDealGetTicket(d);
               if(deal == 0) continue;
               if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != old_ticket) continue;

               string deal_symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
               if(StringLen(symbol) == 0) symbol = deal_symbol;

               long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
               long deal_type = HistoryDealGetInteger(deal, DEAL_TYPE);
               if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
               {
                  entry_price = HistoryDealGetDouble(deal, DEAL_PRICE);
                  volume += HistoryDealGetDouble(deal, DEAL_VOLUME);
                  opened_at = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
                  position_type = (deal_type == DEAL_TYPE_SELL ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
               }
               if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
               {
                  close_price = HistoryDealGetDouble(deal, DEAL_PRICE);
                  profit += HistoryDealGetDouble(deal, DEAL_PROFIT);
                  close_time = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
               }
            }

            if(StringLen(symbol) > 0 && entry_price > 0.0 && close_price > 0.0)
            {
               pips = PositionPips(symbol, position_type, entry_price, close_price);

               string body = StringFormat(
                  "{\"action\":\"CLOSE\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"side\":\"%s\",\"volume\":%.2f,\"price\":%.8f,\"profit\":%.2f,\"pips\":%.2f,\"reason\":\"MANUAL_OR_EXTERNAL_CLOSE\",\"execution_status\":\"SUCCESS\",\"executed_at\":\"%s\"}",
                  JsonEscape(symbol), old_ticket, position_type==POSITION_TYPE_BUY ? "BUY" : "SELL",
                  volume, close_price, profit, pips,
                  TimeToString(close_time, TIME_DATE|TIME_SECONDS));

               string response_text;
               int status;
               HttpRequest("POST", "/execution", body, response_text, status);
               SendTransaction(old_ticket, symbol, position_type==POSITION_TYPE_BUY ? "BUY" : "SELL",
                               volume, entry_price, close_price, pips, profit,
                               "MANUAL_OR_EXTERNAL_CLOSE", opened_at, close_time);
               MarkPositionClosed(old_ticket, symbol, position_type==POSITION_TYPE_BUY ? "BUY" : "SELL",
                                  volume, entry_price, close_price, pips, profit,
                                  "MANUAL_OR_EXTERNAL_CLOSE", opened_at, close_time);
            }


         }
      }
   }

   ArrayResize(known_tickets, ArraySize(current));
   for(int i=0; i<ArraySize(current); i++) known_tickets[i] = current[i];
}

void OnTimer()
{
   datetime now = TimeCurrent();

   if(g_last_config_fetch == 0 || (now - g_last_config_fetch) >= InpConfigRefreshSeconds)
      RefreshConfig();

   if(g_bot_enabled && g_bot_mode == "AUTO" && InpAllowTrading)
   {
      ManagePositions();
      PollAndExecuteSignal();
   }
   else
      SyncOpenPositions();

   if(g_last_sync == 0 || (now - g_last_sync) >= 10)
   {
      SendHeartbeat();
      CheckForManualCloses();
      g_last_sync = now;
   }
}

int OnInit()
{
   g_worker_url = InpWorkerURL;
   while(StringLen(g_worker_url) > 0 && StringSubstr(g_worker_url, StringLen(g_worker_url)-1, 1) == "/")
      g_worker_url = StringSubstr(g_worker_url, 0, StringLen(g_worker_url)-1);

   g_api_key = InpBotAPIKey;

   if(StringLen(g_worker_url) < 8)
      Print("[KBPARI] WARNING: Worker URL is not configured.");
   if(StringLen(g_api_key) == 0)
      Print("[KBPARI] WARNING: Bot API key is not configured.");

   EventSetTimer(MathMax(1, InpTimerSeconds));
   RefreshConfig();

   Print("[KBPARI] MT5 EA 1.011 initialized.");
   Print("[KBPARI] Target Profit and Target Loss are dynamic Worker/Supabase values.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTick()
{
   // Timer-driven architecture prevents repeated actions on every market tick.
}

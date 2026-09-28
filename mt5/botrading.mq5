#property strict
#property version   "1.000"
#property description "KBPARI MT5 Expert Advisor - dynamic configuration from Worker/Supabase"

#include <Trade/Trade.mqh>

CTrade trade;

input string InpWorkerURL = "https://YOUR-WORKER.workers.dev";
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
      "1.000",
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

bool ClosePositionByTicket(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   double pips = PositionPips(
      symbol,
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE),
      PositionGetDouble(POSITION_PRICE_OPEN),
      PositionGetDouble(POSITION_PRICE_CURRENT));

   if(!trade.PositionClose(ticket))
   {
      PrintFormat("[%s] CLOSE failed ticket=%I64u retcode=%d %s",
                  symbol, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }

   string body = StringFormat(
      "{\"action\":\"CLOSE\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"side\":\"%s\",\"volume\":%.2f,\"price\":%.8f,\"profit\":%.2f,\"pips\":%.2f,\"reason\":\"%s\",\"execution_status\":\"SUCCESS\"}",
      JsonEscape(symbol), ticket,
      PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? "BUY" : "SELL",
      PositionGetDouble(POSITION_VOLUME),
      PositionGetDouble(POSITION_PRICE_CURRENT),
      PositionGetDouble(POSITION_PROFIT),
      pips, JsonEscape(reason));

   string response_text;
   int status;
   HttpRequest("POST", "/execution", body, response_text, status);

   PrintFormat("[%s] Position closed ticket=%I64u pips=%.2f reason=%s", symbol, ticket, pips, reason);
   return true;
}

void ManagePositions()
{
   if(g_target_profit_pips <= 0.0) return;

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

      if(pips >= g_target_profit_pips)
      {
         ClosePositionByTicket(ticket, "TARGET_PROFIT_PIPS");
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
            double close_price = 0.0;
            datetime close_time = 0;

            int deals = HistoryDealsTotal();
            for(int d=0; d<deals; d++)
            {
               ulong deal = HistoryDealGetTicket(d);
               if(deal == 0) continue;
               if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != old_ticket) continue;
               long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
               if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
               {
                  profit += HistoryDealGetDouble(deal, DEAL_PROFIT);
                  volume += HistoryDealGetDouble(deal, DEAL_VOLUME);
                  close_price = HistoryDealGetDouble(deal, DEAL_PRICE);
                  close_time = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
               }
            }

            string symbol = "";
            if(deals > 0)
            {
               ulong deal0 = HistoryDealGetTicket(0);
               if(deal0 > 0) symbol = HistoryDealGetString(deal0, DEAL_SYMBOL);
            }

            if(StringLen(symbol) > 0)
            {
               string body = StringFormat(
                  "{\"action\":\"CLOSE\",\"symbol\":\"%s\",\"mt5_ticket\":%I64u,\"volume\":%.2f,\"price\":%.8f,\"profit\":%.2f,\"reason\":\"MANUAL_OR_EXTERNAL_CLOSE\",\"execution_status\":\"SUCCESS\",\"executed_at\":\"%s\"}",
                  JsonEscape(symbol), old_ticket, volume, close_price, profit,
                  TimeToString(close_time, TIME_DATE|TIME_SECONDS));

               string response_text;
               int status;
               HttpRequest("POST", "/execution", body, response_text, status);
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
      ManagePositions();
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

   Print("[KBPARI] MT5 EA 1.000 initialized.");
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

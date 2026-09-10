//+------------------------------------------------------------------+
//| Tedderman_Universal_Client.mq5                                    |
//| Thin, read-only rendering client for Traderman indicator service  |
//+------------------------------------------------------------------+
#property copyright "Traderman.net"
#property link      "https://app.traderman.net"
#property version   "1.01"
#property strict

#define CLIENT_VERSION "1.01"
#define MAX_RESPONSE_BYTES 262144

input string ApiToken = ""; // ApiToken: MT5 Integration Token from Settings
input int PollIntervalSeconds = 15;
input int MaximumBackoffSeconds = 300;
input int SnapshotBars = 32;
input int RequestTimeoutMilliseconds = 10000;
input bool EnableServerSounds = true;
input bool EnableTelegramAlerts = true;
input string TelegramBotToken = "";
input string TelegramChatId = "";
input string InstrumentClass = "auto";
input bool RemoveServerObjectsOnDetach = true;

/*
  Install this file as an Expert Advisor in MQL5/Experts, not as an Indicator.
  Compile with MetaEditor and attach it to a separate chart from TradermanSync.
  First register this broker account with TradermanSync, then paste the SAME
  MT5 Integration Token from Settings into ApiToken in the EA Inputs dialog.
  Paste only the raw token: no "Bearer " prefix, License Key or developer API key.
  Do not put a real token into this source file before compiling or sharing it.

  HTTPS setup: in MT5 open Tools > Options > Expert Advisors, enable
  WebRequest for listed URLs, and add exactly:
      https://app.traderman.net
  For optional delivery through your own Telegram bot also add:
      https://api.telegram.org

  Current v1 rendering response contract (additional server fields are allowed):
  {
    "version": 1,
    "request_id": "opaque",
    "instructions": [
      {"type":"arrow","id":"opaque","time":1710000000,"price":1.2345,
       "direction":"up|down","color":"#RRGGBB","width":1},
      {"type":"box","id":"opaque","time1":1710000000,"price1":1.2,
       "time2":1710000300,"price2":1.3,"color":"#RRGGBB","fill":false},
      {"type":"sl|tp|line","role":"sl|tp|line","id":"opaque","price":1.2,
       "label":"server text","color":"#RRGGBB","width":1},
      {"type":"hud","id":"opaque","text":"server text","corner":0,
       "x":10,"y":20,"color":"#RRGGBB","size":10}
    ],
    "sound": {"play":true,"file":"alert.wav"}
  }
  Unknown/malformed fields and instruction types are ignored. On every valid
  HTTP 2xx v1 response, objects omitted by the server are removed. This EA
  never infers a signal or draws from local analysis. The ten user mechanics
  (panic_candle_arrows, sound_alerts, mini_dashboard_hud, gold_sniper_mode,
  liquidity_block_boxes, anti_chop_filter, dynamic_sl_tp,
  volume_surge_delta, telegram_alerts, and us30_momentum_mode) remain
  server-owned and can affect the chart only through this instruction array.
  The request is GET /api/v1/indicator/sync with the raw MT5 Integration Token in
  Authorization: Bearer;
  the service hashes that token before lookup, as does TradermanSync.mq5.
  The token is never put in the URL, terminal log, object, or GlobalVariable.

  Required query contract:
    account_number, symbol, timeframe, bar_time, open, high, low, close, atr,
    prior_high, prior_low, trend_strength, tick_volume, average_volume,
    point_size, and optional instrument_class
  `open` through `close` and `tick_volume` describe the last closed bar.
  ATR, prior range, and normalized [0,1] trend strength are computed from a
  bounded 12-48 bar window. Average volume uses only earlier closed candles,
  excluding the signal candle. These are market inputs only and are never
  interpreted as client-side signals. The optional Telegram credentials are
  used only for a direct sendMessage request and are never logged or persisted.
  `account_number` uses the same canonical login@ACCOUNT_SERVER external ID as
  TradermanSync.mq5. Bar times are normalized from broker chart time to UTC in
  requests and converted from UTC back to chart time when rendering.
*/

const string SERVICE_URL = "https://app.traderman.net/api/v1/indicator/sync";
bool RequestInProgress = false;
datetime NextRequestAt = 0;
int FailureCount = 0;
string ObjectPrefix = "";
string LockKey = "";
string NotificationKey = "";
int PollBrokerUtcOffsetSeconds = 0;

int BoundInt(int value, int minimum, int maximum)
{
   return MathMax(minimum, MathMin(maximum, value));
}

bool BuildAuthorizationHeaders(string token, string &headers)
{
   headers = "";
   // Clipboard whitespace around the token is not part of the credential.
   StringTrimLeft(token);
   StringTrimRight(token);
   if(StringLen(token) < 10 || StringLen(token) > 4096)
      return false;
   // Reject prefixes, embedded whitespace and control characters before HTTP.
   // Do not enforce a token prefix: the existing server hash lookup is authoritative.
   for(int index = 0; index < StringLen(token); index++)
   {
      ushort character = StringGetCharacter(token, index);
      if(character <= 32 || character == 127)
         return false;
   }
   headers =
      "Accept: application/json\r\n"
      "Authorization: Bearer " + token + "\r\n";
   return true;
}

string UrlEncode(string value)
{
   uchar bytes[];
   int count = StringToCharArray(value, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   string encoded = "";
   for(int index = 0; index < count - 1; index++)
   {
      int item = (int)bytes[index];
      bool safe =
         (item >= 'a' && item <= 'z') ||
         (item >= 'A' && item <= 'Z') ||
         (item >= '0' && item <= '9') ||
         item == '-' || item == '_' || item == '.' || item == '~';
      if(safe)
         encoded += CharToString((uchar)item);
      else
         encoded += StringFormat("%%%02X", item);
   }
   return encoded;
}

string JsonUnescape(string value)
{
   StringReplace(value, "\\\"", "\"");
   StringReplace(value, "\\/", "/");
   StringReplace(value, "\\n", "\n");
   StringReplace(value, "\\r", "\r");
   StringReplace(value, "\\t", "\t");
   StringReplace(value, "\\\\", "\\");
   return value;
}

bool JsonRawValue(const string json, const string key, string &result)
{
   string needle = "\"" + key + "\"";
   int key_at = StringFind(json, needle);
   if(key_at < 0)
      return false;
   int colon = StringFind(json, ":", key_at + StringLen(needle));
   if(colon < 0)
      return false;
   int length = StringLen(json);
   int start = colon + 1;
   while(start < length)
   {
      ushort ch = StringGetCharacter(json, start);
      if(ch != ' ' && ch != '\r' && ch != '\n' && ch != '\t')
         break;
      start++;
   }
   if(start >= length)
      return false;

   ushort first = StringGetCharacter(json, start);
   if(first == '"')
   {
      bool escaped = false;
      for(int pos = start + 1; pos < length; pos++)
      {
         ushort ch = StringGetCharacter(json, pos);
         if(ch == '"' && !escaped)
         {
            result = StringSubstr(json, start, pos - start + 1);
            return true;
         }
         if(ch == '\\' && !escaped)
            escaped = true;
         else
            escaped = false;
      }
      return false;
   }
   if(first == '[' || first == '{')
   {
      ushort closing = first == '[' ? ']' : '}';
      int depth = 0;
      bool in_string = false;
      bool escaped = false;
      for(int pos = start; pos < length; pos++)
      {
         ushort ch = StringGetCharacter(json, pos);
         if(in_string)
         {
            if(ch == '"' && !escaped)
               in_string = false;
            if(ch == '\\' && !escaped)
               escaped = true;
            else
               escaped = false;
            continue;
         }
         if(ch == '"')
         {
            in_string = true;
            continue;
         }
         if(ch == first)
            depth++;
         else if(ch == closing)
         {
            depth--;
            if(depth == 0)
            {
               result = StringSubstr(json, start, pos - start + 1);
               return true;
            }
         }
      }
      return false;
   }
   int end = start;
   while(end < length)
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == ',' || ch == '}' || ch == ']' || ch == '\r' || ch == '\n')
         break;
      end++;
   }
   result = StringSubstr(json, start, end - start);
   StringTrimLeft(result);
   StringTrimRight(result);
   return StringLen(result) > 0;
}

bool JsonString(const string json, const string key, string &value)
{
   string raw;
   if(!JsonRawValue(json, key, raw) || StringLen(raw) < 2)
      return false;
   if(StringGetCharacter(raw, 0) != '"' ||
      StringGetCharacter(raw, StringLen(raw) - 1) != '"')
      return false;
   value = JsonUnescape(StringSubstr(raw, 1, StringLen(raw) - 2));
   return true;
}

bool JsonNumber(const string json, const string key, double &value)
{
   string raw;
   if(!JsonRawValue(json, key, raw))
      return false;
   value = StringToDouble(raw);
   if(!MathIsValidNumber(value))
      return false;
   if(value == 0.0 && raw != "0" && raw != "0.0")
   {
      int zero_at = StringFind(raw, "0");
      if(zero_at < 0)
         return false;
   }
   return true;
}

bool JsonBool(const string json, const string key, bool &value)
{
   string raw;
   if(!JsonRawValue(json, key, raw))
      return false;
   StringToLower(raw);
   if(raw == "true")
   {
      value = true;
      return true;
   }
   if(raw == "false")
   {
      value = false;
      return true;
   }
   return false;
}

ulong StableHash(string value)
{
   ulong hash = 1469598103934665603;
   for(int index = 0; index < StringLen(value); index++)
   {
      hash ^= (ulong)StringGetCharacter(value, index);
      hash *= 1099511628211;
   }
   return hash;
}

string ManagedName(const string type, const string server_id)
{
   return ObjectPrefix + type + "_" + IntegerToString((long)StableHash(server_id));
}

bool ParseColor(string text, color &result)
{
   if(StringLen(text) != 7 || StringGetCharacter(text, 0) != '#')
      return false;
   int rgb = 0;
   for(int index = 1; index < 7; index++)
   {
      ushort ch = StringGetCharacter(text, index);
      int digit = -1;
      if(ch >= '0' && ch <= '9')
         digit = ch - '0';
      else if(ch >= 'a' && ch <= 'f')
         digit = ch - 'a' + 10;
      else if(ch >= 'A' && ch <= 'F')
         digit = ch - 'A' + 10;
      if(digit < 0)
         return false;
      rgb = rgb * 16 + digit;
   }
   int red = (rgb >> 16) & 255;
   int green = (rgb >> 8) & 255;
   int blue = rgb & 255;
   result = (color)(red | (green << 8) | (blue << 16));
   return true;
}

color InstructionColor(const string item, color fallback)
{
   string text;
   color parsed;
   if(JsonString(item, "color", text) && ParseColor(text, parsed))
      return parsed;
   return fallback;
}

bool AddExpected(string &expected, const string name)
{
   if(StringFind(expected, "|" + name + "|") >= 0)
      return false;
   expected += name + "|";
   return true;
}

datetime UtcToBrokerChartTime(double utc_epoch)
{
   return (datetime)((long)utc_epoch + (long)PollBrokerUtcOffsetSeconds);
}

bool RenderArrow(const string item, const string id, string &expected)
{
   double raw_time, price;
   string direction;
   if(!JsonNumber(item, "time", raw_time) || !JsonNumber(item, "price", price) ||
      !JsonString(item, "direction", direction) || raw_time <= 0 ||
      price <= 0 || !MathIsValidNumber(price))
      return false;
   StringToLower(direction);
   if(direction != "up" && direction != "down")
      return false;
   string name = ManagedName("arrow", id);
   AddExpected(expected, name);
   if(ObjectFind(0, name) < 0 &&
      !ObjectCreate(0, name, OBJ_ARROW, 0, UtcToBrokerChartTime(raw_time), price))
      return false;
   ObjectMove(0, name, 0, UtcToBrokerChartTime(raw_time), price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, direction == "up" ? 233 : 234);
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    InstructionColor(item, direction == "up" ? clrLime : clrRed));
   double raw_width = 1;
   JsonNumber(item, "width", raw_width);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, BoundInt((int)raw_width, 1, 5));
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   return true;
}

bool RenderBox(const string item, const string id, string &expected)
{
   double time1, time2, price1, price2;
   if(!JsonNumber(item, "time1", time1) || !JsonNumber(item, "time2", time2) ||
      !JsonNumber(item, "price1", price1) || !JsonNumber(item, "price2", price2) ||
      time1 <= 0 || time2 <= 0 || price1 <= 0 || price2 <= 0)
      return false;
   string name = ManagedName("box", id);
   AddExpected(expected, name);
   if(ObjectFind(0, name) < 0 &&
      !ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                    UtcToBrokerChartTime(time1), price1,
                    UtcToBrokerChartTime(time2), price2))
      return false;
   ObjectMove(0, name, 0, UtcToBrokerChartTime(time1), price1);
   ObjectMove(0, name, 1, UtcToBrokerChartTime(time2), price2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InstructionColor(item, clrDodgerBlue));
   bool fill = false;
   JsonBool(item, "fill", fill);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   return true;
}

bool RenderLevel(const string item, const string id, string type, string &expected)
{
   double price;
   if(!JsonNumber(item, "price", price) || price <= 0)
      return false;
   string role = type;
   if(type == "line")
      JsonString(item, "role", role);
   StringToLower(role);
   if(role != "sl" && role != "tp" && role != "line")
      return false;
   string name = ManagedName(role, id);
   AddExpected(expected, name);
   if(ObjectFind(0, name) < 0 && !ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
      return false;
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   color fallback = clrDodgerBlue;
   if(role == "sl")
      fallback = clrTomato;
   else if(role == "tp")
      fallback = clrLimeGreen;
   ObjectSetInteger(0, name, OBJPROP_COLOR, InstructionColor(item, fallback));
   double raw_width = 1;
   JsonNumber(item, "width", raw_width);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, BoundInt((int)raw_width, 1, 5));
   string label;
   if(!JsonString(item, "label", label) || StringLen(label) > 120)
   {
      label = role;
      StringToUpper(label);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, label);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   return true;
}

bool RenderHud(const string item, const string id, string &expected)
{
   string text;
   if(!JsonString(item, "text", text))
      return false;
   if(StringLen(text) > 1000)
      text = StringSubstr(text, 0, 1000);
   string name = ManagedName("hud", id);
   AddExpected(expected, name);
   if(ObjectFind(0, name) < 0 && !ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return false;
   double corner = 0, x = 10, y = 20, size = 10;
   JsonNumber(item, "corner", corner);
   JsonNumber(item, "x", x);
   JsonNumber(item, "y", y);
   JsonNumber(item, "size", size);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_CORNER, BoundInt((int)corner, 0, 3));
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, BoundInt((int)x, 0, 3000));
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, BoundInt((int)y, 0, 3000));
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, BoundInt((int)size, 7, 24));
   ObjectSetInteger(0, name, OBJPROP_COLOR, InstructionColor(item, clrWhite));
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   return true;
}

void RemoveStaleObjects(const string expected)
{
   for(int index = ObjectsTotal(0, -1, -1) - 1; index >= 0; index--)
   {
      string name = ObjectName(0, index, -1, -1);
      if(StringFind(name, ObjectPrefix) == 0 &&
         StringFind(expected, "|" + name + "|") < 0)
         ObjectDelete(0, name);
   }
}

bool SendTelegramMessage(const string text)
{
   if(StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatId) < 1)
      return false;
   string bounded_text = StringSubstr(text, 0, 1000);
   string endpoint = "https://api.telegram.org/bot" + TelegramBotToken + "/sendMessage";
   string payload =
      "chat_id=" + UrlEncode(TelegramChatId) +
      "&text=" + UrlEncode(bounded_text);
   char body[];
   char response[];
   string response_headers;
   int length = StringToCharArray(payload, body, 0, WHOLE_ARRAY, CP_UTF8);
   if(length > 0)
      ArrayResize(body, length - 1);
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   ResetLastError();
   int status = WebRequest(
      "POST",
      endpoint,
      headers,
      BoundInt(RequestTimeoutMilliseconds, 1000, 15000),
      body,
      response,
      response_headers
   );
   if(status == -1)
   {
      Print("Telegram delivery failed. Allow https://api.telegram.org in MT5 WebRequest settings.");
      return false;
   }
   if(status < 200 || status >= 300)
   {
      Print("Telegram delivery was rejected with HTTP ", status, ".");
      return false;
   }
   Print("Telegram alert delivered.");
   return true;
}

double NotificationId(const string request_id)
{
   // GlobalVariables store exact integers only through 2^53. Persist only this
   // opaque event fingerprint, never credentials, Telegram text, or payloads.
   ulong bounded = StableHash(request_id) % 9007199254740991;
   return (double)bounded;
}

void HandleNotifications(const string json)
{
   string request_id;
   if(!JsonString(json, "request_id", request_id) ||
      StringLen(request_id) < 1 || StringLen(request_id) > 200)
      return;
   double notification_id = NotificationId(request_id);
   if(GlobalVariableCheck(NotificationKey) &&
      GlobalVariableGet(NotificationKey) == notification_id)
      return;

   // Claim before external effects: replaying a closed candle never repeats
   // either sound or Telegram, including after an EA/terminal restart.
   GlobalVariableSet(NotificationKey, notification_id);

   string sound;
   if(EnableServerSounds && JsonRawValue(json, "sound", sound))
   {
      bool play = false;
      string file;
      if(JsonBool(sound, "play", play) && play && JsonString(sound, "file", file) &&
         StringLen(file) > 4 && StringLen(file) <= 64 &&
         StringFind(file, "/") < 0 && StringFind(file, "\\") < 0 &&
         StringFind(file, ":") < 0 && StringFind(file, "..") < 0)
      {
         string lower_file = file;
         StringToLower(lower_file);
         if(StringSubstr(lower_file, StringLen(lower_file) - 4) == ".wav")
            PlaySound(file);
      }
   }

   string telegram, enabled;
   bool send = false;
   bool telegram_enabled = false;
   string text;
   if(!EnableTelegramAlerts ||
      !JsonRawValue(json, "enabled", enabled) ||
      !JsonBool(enabled, "telegram_alerts", telegram_enabled) ||
      !telegram_enabled ||
      !JsonRawValue(json, "telegram", telegram) ||
      !JsonBool(telegram, "send", send) ||
      !send ||
      !JsonString(telegram, "text", text) ||
      StringLen(text) < 1)
      return;
   if(StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatId) < 1)
   {
      Print("Telegram alert requested: set TelegramBotToken and TelegramChatId, then allow api.telegram.org.");
      return;
   }
   SendTelegramMessage(text);
}

bool RenderResponse(const string json)
{
   double version;
   string instructions;
   if(!JsonNumber(json, "version", version) || (int)version != 1 ||
      !JsonRawValue(json, "instructions", instructions) ||
      StringLen(instructions) < 2 ||
      StringGetCharacter(instructions, 0) != '[')
      return false;

   string expected = "|";
   int depth = 0;
   int object_start = -1;
   bool in_string = false;
   bool escaped = false;
   int instruction_count = 0;
   for(int pos = 1; pos < StringLen(instructions) - 1; pos++)
   {
      ushort ch = StringGetCharacter(instructions, pos);
      if(in_string)
      {
         if(ch == '"' && !escaped)
            in_string = false;
         if(ch == '\\' && !escaped)
            escaped = true;
         else
            escaped = false;
         continue;
      }
      if(ch == '"')
      {
         in_string = true;
         continue;
      }
      if(ch == '{')
      {
         if(depth == 0)
            object_start = pos;
         depth++;
      }
      else if(ch == '}' && depth > 0)
      {
         depth--;
         if(depth == 0 && object_start >= 0 && instruction_count < 200)
         {
            string item = StringSubstr(instructions, object_start, pos - object_start + 1);
            string type, id;
            if(JsonString(item, "type", type) && JsonString(item, "id", id) &&
               StringLen(id) > 0 && StringLen(id) <= 200)
            {
               StringToLower(type);
               if(type == "arrow")
                  RenderArrow(item, id, expected);
               else if(type == "box")
                  RenderBox(item, id, expected);
               else if(type == "sl" || type == "tp" || type == "line")
                  RenderLevel(item, id, type, expected);
               else if(type == "hud")
                  RenderHud(item, id, expected);
            }
            instruction_count++;
            object_start = -1;
         }
      }
   }
   if(depth != 0 || in_string)
      return false;
   RemoveStaleObjects(expected);
   ChartRedraw(0);
   HandleNotifications(json);
   return true;
}

bool SnapshotMetrics(
   const MqlRates &rates[],
   int count,
   double point_size,
   double &atr,
   double &prior_high,
   double &prior_low,
   double &trend_strength,
   double &average_volume
)
{
   if(count < 12 || point_size <= 0 || !MathIsValidNumber(point_size))
      return false;

   // rates[0] is forming, rates[1] is the signal candle, rates[2+] are prior.
   int completed = MathMin(14, count - 3);
   if(completed < 2)
      return false;
   atr = 0.0;
   average_volume = 0.0;
   prior_high = rates[2].high;
   prior_low = rates[2].low;
   for(int offset = 0; offset < completed; offset++)
   {
      int index = offset + 2;
      double true_range = MathMax(
         rates[index].high - rates[index].low,
         MathMax(
            MathAbs(rates[index].high - rates[index + 1].close),
            MathAbs(rates[index].low - rates[index + 1].close)
         )
      );
      atr += true_range;
      average_volume += (double)rates[index].tick_volume;
      prior_high = MathMax(prior_high, rates[index].high);
      prior_low = MathMin(prior_low, rates[index].low);
   }
   atr = MathMax(atr / completed, point_size);
   average_volume /= completed;
   if(average_volume <= 0.0 || average_volume > 2147483647.0)
      return false;

   // Directional efficiency is a bounded [0,1] trend input, not a signal.
   double travelled = 0.0;
   for(int index = 2; index <= completed + 1; index++)
      travelled += MathAbs(rates[index - 1].close - rates[index].close);
   trend_strength = 0.0;
   if(travelled > point_size)
      trend_strength =
         MathAbs(rates[1].close - rates[completed + 1].close) / travelled;
   trend_strength = MathMax(0.0, MathMin(1.0, trend_strength));

   return
      MathIsValidNumber(atr) && atr >= 0.0 &&
      MathIsValidNumber(prior_high) && prior_high > 0.0 &&
      MathIsValidNumber(prior_low) && prior_low > 0.0;
}

string TimeframeName()
{
   string name = EnumToString(_Period);
   StringReplace(name, "PERIOD_", "");
   return name;
}

string NormalizedInstrumentClass()
{
   string value = InstrumentClass;
   StringToLower(value);
   if(value != "auto" && value != "other" && value != "gold" && value != "us30")
      return "";
   return value;
}

bool BuildRequestUrl(string &url)
{
   int requested = BoundInt(SnapshotBars, 12, 48);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int count = CopyRates(_Symbol, _Period, 0, requested, rates);
   if(count < 12)
      return false;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
      return false;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   digits = BoundInt(digits, 0, 8);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(!MathIsValidNumber(point) || point < 0.00000001 || point > 100000.0)
      return false;
   double atr, prior_high, prior_low, trend_strength, average_volume;
   if(!SnapshotMetrics(
      rates, count, point, atr, prior_high, prior_low, trend_strength,
      average_volume
   ))
      return false;
   string timeframe = TimeframeName();
   if(timeframe != "M1" && timeframe != "M5" && timeframe != "M15" &&
      timeframe != "M30" && timeframe != "H1" && timeframe != "H4" &&
      timeframe != "D1")
      return false;
   string instrument_class = NormalizedInstrumentClass();
   if(instrument_class == "")
      return false;
   long tick_volume = rates[1].tick_volume;
   if(tick_volume < 0 || tick_volume > 2147483647)
      return false;
   datetime broker_now = TimeTradeServer();
   datetime utc_now = TimeGMT();
   if(broker_now <= 0 || utc_now <= 0)
      return false;
   long raw_offset = (long)broker_now - (long)utc_now;
   if(raw_offset < -64800 || raw_offset > 64800)
      return false;
   // Capture once for this request/response pair so DST or a clock tick cannot
   // produce different request and rendering offsets within the same poll.
   // Broker UTC offsets are minute-based; rounding also removes a possible
   // one-second skew between the two sequential clock reads.
   if(raw_offset >= 0)
      PollBrokerUtcOffsetSeconds = (int)((raw_offset + 30) / 60) * 60;
   else
      PollBrokerUtcOffsetSeconds = (int)((raw_offset - 30) / 60) * 60;
   long closed_bar_utc =
      (long)rates[1].time - (long)PollBrokerUtcOffsetSeconds;
   if(closed_bar_utc <= 0 || closed_bar_utc > 4102444800)
      return false;
   string canonical_account =
      IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "@" +
      AccountInfoString(ACCOUNT_SERVER);

   url = SERVICE_URL +
      "?account_number=" + UrlEncode(canonical_account) +
      "&symbol=" + UrlEncode(_Symbol) +
      "&timeframe=" + UrlEncode(timeframe) +
      "&bar_time=" + IntegerToString(closed_bar_utc) +
      "&open=" + DoubleToString(rates[1].open, digits) +
      "&high=" + DoubleToString(rates[1].high, digits) +
      "&low=" + DoubleToString(rates[1].low, digits) +
      "&close=" + DoubleToString(rates[1].close, digits) +
      "&atr=" + DoubleToString(atr, digits) +
      "&prior_high=" + DoubleToString(prior_high, digits) +
      "&prior_low=" + DoubleToString(prior_low, digits) +
      "&trend_strength=" + DoubleToString(trend_strength, 4) +
      "&tick_volume=" + IntegerToString(tick_volume) +
      "&average_volume=" + DoubleToString(average_volume, 2) +
      "&point_size=" + DoubleToString(point, 8) +
      "&instrument_class=" + UrlEncode(instrument_class);
   return StringLen(url) <= 12000;
}

void ScheduleNext(bool success)
{
   int base = BoundInt(PollIntervalSeconds, 5, 300);
   int ceiling = BoundInt(MaximumBackoffSeconds, base, 1800);
   if(success)
   {
      FailureCount = 0;
      NextRequestAt = TimeLocal() + base;
      return;
   }
   FailureCount = MathMin(FailureCount + 1, 8);
   int delay = base;
   for(int index = 0; index < FailureCount && delay < ceiling; index++)
      delay = MathMin(delay * 2, ceiling);
   NextRequestAt = TimeLocal() + delay;
}

void Synchronize()
{
   if(RequestInProgress || TimeLocal() < NextRequestAt)
      return;
   RequestInProgress = true;
   GlobalVariableSet(LockKey, (double)TimeLocal());

   bool success = false;
   string url;
   string headers;
   if(!BuildAuthorizationHeaders(ApiToken, headers))
   {
      Print("Tedderman client is paused: copy the MT5 Integration Token (API Token) "
            "from Settings into ApiToken. Paste only the token, without a Bearer prefix.");
   }
   else if(!BuildRequestUrl(url))
   {
      Print("Tedderman client could not capture enough live market data for ", _Symbol, ".");
   }
   else
   {
      char request_body[];
      char response[];
      string response_headers;
      ResetLastError();
      int status = WebRequest(
         "GET", url, headers,
         BoundInt(RequestTimeoutMilliseconds, 1000, 30000),
         request_body, response, response_headers
      );
      if(status == -1)
      {
         Print("Tedderman client HTTPS request failed (", GetLastError(),
               "). Allow https://app.traderman.net in Tools > Options > Expert Advisors > WebRequest.");
      }
      else if(status < 200 || status >= 300)
      {
         // Deliberately do not print response bodies: they may contain private data.
         Print("Tedderman indicator service returned HTTP ", status, ".");
      }
      else if(ArraySize(response) > MAX_RESPONSE_BYTES)
      {
         Print("Tedderman indicator response exceeded the safe size limit.");
      }
      else
      {
         string response_text = CharArrayToString(response, 0, WHOLE_ARRAY, CP_UTF8);
         success = RenderResponse(response_text);
         if(!success)
            Print("Tedderman indicator service returned an unsupported or malformed v1 response.");
      }
   }
   ScheduleNext(success);
   GlobalVariableSet(LockKey, 0.0);
   RequestInProgress = false;
}

int OnInit()
{
   string identity =
      IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" +
      AccountInfoString(ACCOUNT_SERVER) + "_" +
      IntegerToString(ChartID()) + "_" + _Symbol + "_" +
      IntegerToString((int)_Period);
   string suffix = IntegerToString((long)StableHash(identity));
   ObjectPrefix = "TMUC_" + suffix + "_";
   LockKey = "TMUC_LOCK_" + suffix;
   string notification_identity =
      IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" +
      AccountInfoString(ACCOUNT_SERVER) + "_" +
      _Symbol + "_" + IntegerToString((int)_Period);
   NotificationKey =
      "TMUC_EVENT_" + IntegerToString((long)StableHash(notification_identity));

   if(GlobalVariableCheck(LockKey))
   {
      datetime held_at = (datetime)GlobalVariableGet(LockKey);
      if(held_at > 0 && TimeLocal() - held_at < 60)
      {
         Print("Tedderman client is already active for this account/chart/symbol.");
         return INIT_FAILED;
      }
   }
   GlobalVariableSet(LockKey, 0.0);
   EventSetTimer(1);
   NextRequestAt = 0;
   Synchronize();
   return INIT_SUCCEEDED;
}

void OnTimer()
{
   Synchronize();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(RemoveServerObjectsOnDetach)
      ObjectsDeleteAll(0, ObjectPrefix);
   if(GlobalVariableCheck(LockKey))
      GlobalVariableDel(LockKey);
   // NotificationKey intentionally survives detach to suppress replay. It
   // contains only an opaque event fingerprint, never a secret or message.
   ChartRedraw(0);
}
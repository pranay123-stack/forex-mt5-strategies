//+------------------------------------------------------------------+
//| LiquidityMarketMap_EA.mq5                                         |
//| Liquidity Market Map V1 - iFVG Execution Strategy                 |
//| SMC: iFVG, FVG, Breaker Blocks, Rejection Blocks                 |
//| Multi-TF top-down analysis with 15s precision execution           |
//+------------------------------------------------------------------+
#property strict
#property copyright "Liquidity Market Map EA V1"
#property version   "1.00"
#property description "iFVG-based SMC execution strategy"
#property description "NQ/NASDAQ Futures | NY & Asia Sessions"
#property description "Multi-TF zone detection with risk-based sizing"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Structures for zone tracking                                     |
//+------------------------------------------------------------------+
struct Zone
{
   double   top;           // Upper boundary
   double   bottom;        // Lower boundary
   double   midpoint;      // (top + bottom) / 2
   datetime time;          // When zone was created
   int      direction;     // +1 = bullish, -1 = bearish
   int      zoneType;      // 0=FVG, 1=iFVG, 2=Breaker, 3=Rejection
   ENUM_TIMEFRAMES tf;     // Timeframe zone was detected on
   bool     valid;         // Still active (not closed through)
   bool     tested;        // Price has entered the zone
};

//+------------------------------------------------------------------+
//| Input Parameters - General Settings                              |
//+------------------------------------------------------------------+
input group "=== General Settings ==="
input int      MagicNumber        = 20250526;   // Magic Number
input string   TradeSymbol        = "";          // Symbol (empty = current chart)

//+------------------------------------------------------------------+
//| Input Parameters - Session Filter                                |
//+------------------------------------------------------------------+
input group "=== Session Filter (ET/New York Time) ==="
input bool     UseSessionFilter   = true;        // Enable Session Filter
input int      NY_StartHour       = 9;           // NY Session Start Hour (ET)
input int      NY_StartMin        = 30;          // NY Session Start Minute
input int      NY_EndHour         = 12;          // NY Session End Hour (ET)
input int      NY_EndMin          = 0;           // NY Session End Minute
input int      Asia_StartHour     = 20;          // Asia Session Start Hour (ET)
input int      Asia_EndHour       = 0;           // Asia Session End Hour (ET, next day)
input int      ServerGMTOffset    = -5;          // Server GMT offset (ET = GMT-5, adjust for your broker)

//+------------------------------------------------------------------+
//| Input Parameters - Zone Detection                                |
//+------------------------------------------------------------------+
input group "=== Zone Detection ==="
input int      SwingLookback      = 10;          // Swing Point Lookback Bars
input int      RejectionBodyMult  = 2;           // Rejection Block: body must be Nx avg body
input double   RejectionCloseZone = 0.25;        // Rejection Block: close in top/bottom X of range
input int      MaxZonesPerTF      = 5;           // Max zones stored per timeframe
input bool     UseiFVGOnly        = false;       // Only trade iFVG zones (strictest mode)

//+------------------------------------------------------------------+
//| Input Parameters - Entry Settings                                |
//+------------------------------------------------------------------+
input group "=== Entry Settings ==="
input bool     RequireHTFBias     = true;        // Require HTF bias alignment
input int      MinHTFZoneWeight   = 3;           // Minimum HTF zone weight to trade (1-5)

//+------------------------------------------------------------------+
//| Input Parameters - Risk Management                               |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double   DollarRisk         = 400.0;       // Dollar Risk Per Trade
input double   PointValue         = 20.0;        // Point Value (NQ=$20, ES=$12.50)
input double   FixedLotSize       = 0.1;         // Fixed Lot (used if DollarRisk=0)
input int      MaxActiveTrades    = 2;           // Max Simultaneous Trades
input int      MaxSessionStopouts = 2;           // Max Stop-outs Per Session (then stop)
input bool     UseBreakeven       = true;        // Move SL to Breakeven at 1R
input double   BreakevenBuffer    = 2.0;         // Breakeven buffer in points above entry
input double   MaxSLMultiplier    = 1.5;         // Max SL as multiple of avg range (skip if exceeded)

//+------------------------------------------------------------------+
//| Input Parameters - Take Profit                                   |
//+------------------------------------------------------------------+
input group "=== Take Profit ==="
input double   DefaultRR          = 0.9;         // Default R:R if no structural target (0.9R)
input bool     UseStructuralTP    = true;        // Use previous swing high/low as TP

//+------------------------------------------------------------------+
//| Constants for zone types                                         |
//+------------------------------------------------------------------+
#define ZONE_FVG        0
#define ZONE_IFVG       1
#define ZONE_BREAKER    2
#define ZONE_REJECTION  3

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
string symbol;

// Zone storage — one array per timeframe concept
Zone g_zones[];
int  g_zoneCount;

// Session tracking
int  g_sessionStopouts;
datetime g_lastSessionDate;

// HTF bias: +1 bullish, -1 bearish, 0 neutral
int  g_htfBias;

// Timeframes for zone detection (7 levels)
ENUM_TIMEFRAMES g_timeframes[7];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set symbol
   symbol = (TradeSymbol == "" || TradeSymbol == NULL) ? _Symbol : TradeSymbol;

   //--- Initialize timeframe array (top-down)
   g_timeframes[0] = PERIOD_D1;
   g_timeframes[1] = PERIOD_H4;
   g_timeframes[2] = PERIOD_H2;
   g_timeframes[3] = PERIOD_H1;
   g_timeframes[4] = PERIOD_M30;
   g_timeframes[5] = PERIOD_M15;
   g_timeframes[6] = PERIOD_M5;

   //--- Initialize zones
   g_zoneCount = 0;
   ArrayResize(g_zones, 200);

   //--- Initialize session tracking
   g_sessionStopouts = 0;
   g_lastSessionDate = 0;
   g_htfBias = 0;

   //--- Set up trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Print startup
   Print("============================================");
   Print("Liquidity Market Map EA V1 Initialized");
   Print("Symbol: ", symbol, " | Execution TF: ", EnumToString(Period()));
   Print("Dollar Risk: $", DollarRisk, " | Point Value: $", PointValue);
   Print("Max Trades: ", MaxActiveTrades, " | Max Stopouts/Session: ", MaxSessionStopouts);
   Print("Session Filter: ", UseSessionFilter ? "ON" : "OFF");
   Print("Breakeven at 1R: ", UseBreakeven ? "ON" : "OFF");
   Print("============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Liquidity Market Map EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Reset session stop-out counter on new day
   ResetSessionCounter();

   //--- Manage breakeven on existing positions
   if(UseBreakeven)
      ManageBreakeven();

   //--- Only process new signals on new bar
   if(!IsNewBar())
      return;

   //--- Check session stop-out limit
   if(g_sessionStopouts >= MaxSessionStopouts)
      return;

   //--- Session filter
   if(UseSessionFilter && !IsWithinSession())
      return;

   //--- Scan zones across all timeframes (top-down)
   ScanAllTimeframeZones();

   //--- Determine HTF bias from Daily/4H zones
   DetermineHTFBias();

   //--- Invalidate zones that price has closed through
   InvalidateZones();

   //--- Check for iFVG entry signals on execution timeframe
   CheckEntrySignals();
}

//+------------------------------------------------------------------+
//| Detect new bar                                                   |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(symbol, PERIOD_CURRENT, 0);
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Reset session stop-out counter on new trading day                |
//+------------------------------------------------------------------+
void ResetSessionCounter()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != g_lastSessionDate)
   {
      g_sessionStopouts = 0;
      g_lastSessionDate = today;
   }
}

//+------------------------------------------------------------------+
//| Check if current time is within NY or Asia session               |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   // Convert server time to ET (approximate using offset)
   int etHour = dt.hour + ServerGMTOffset + 5; // Server GMT + adjustment to get ET
   if(etHour < 0) etHour += 24;
   if(etHour >= 24) etHour -= 24;
   int etMin = dt.min;

   // NY Session: 9:30 - 12:00 ET
   int nyStartMins = NY_StartHour * 60 + NY_StartMin;
   int nyEndMins = NY_EndHour * 60 + NY_EndMin;
   int currentMins = etHour * 60 + etMin;

   if(currentMins >= nyStartMins && currentMins < nyEndMins)
      return true;

   // Asia Session: 20:00 - 24:00 ET (wraps midnight)
   if(Asia_EndHour == 0) // midnight
   {
      if(etHour >= Asia_StartHour && etHour <= 23)
         return true;
   }
   else
   {
      if(etHour >= Asia_StartHour || etHour < Asia_EndHour)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Scan all 7 timeframes for FVG, Breaker, Rejection zones         |
//+------------------------------------------------------------------+
void ScanAllTimeframeZones()
{
   for(int t = 0; t < 7; t++)
   {
      ENUM_TIMEFRAMES tf = g_timeframes[t];

      // Only rescan if a new bar has formed on this timeframe
      static datetime lastBarTF[7] = {0, 0, 0, 0, 0, 0, 0};
      datetime tfBarTime = iTime(symbol, tf, 0);
      if(tfBarTime == lastBarTF[t])
         continue;
      lastBarTF[t] = tfBarTime;

      DetectFVGs(tf);
      DetectBreakerBlocks(tf);
      DetectRejectionBlocks(tf);
      DetectiFVGs(tf);
   }
}

//+------------------------------------------------------------------+
//| Detect Fair Value Gaps on a specific timeframe                   |
//| FVG = 3-candle formation with gap between candle[0] and candle[2]|
//+------------------------------------------------------------------+
void DetectFVGs(ENUM_TIMEFRAMES tf)
{
   double high[3], low[3], close[3], open[3];
   datetime time[3];

   // Get last 3 closed bars (bar 1, 2, 3)
   for(int i = 0; i < 3; i++)
   {
      high[i]  = iHigh(symbol, tf, i + 1);
      low[i]   = iLow(symbol, tf, i + 1);
      close[i] = iClose(symbol, tf, i + 1);
      open[i]  = iOpen(symbol, tf, i + 1);
      time[i]  = iTime(symbol, tf, i + 1);
   }

   // Bullish FVG: high of candle[2] < low of candle[0]
   // (candle indices: [0]=most recent closed, [2]=oldest of the three)
   if(high[2] < low[0])
   {
      AddZone(low[0], high[2], +1, ZONE_FVG, tf, time[1]);
   }

   // Bearish FVG: low of candle[2] > high of candle[0]
   if(low[2] > high[0])
   {
      AddZone(low[2], high[0], -1, ZONE_FVG, tf, time[1]);
   }
}

//+------------------------------------------------------------------+
//| Detect Inverse Fair Value Gaps (iFVGs)                           |
//| An iFVG forms when price closes through an existing FVG          |
//| Bullish FVG closed through from above → becomes bearish iFVG     |
//| Bearish FVG closed through from below → becomes bullish iFVG     |
//+------------------------------------------------------------------+
void DetectiFVGs(ENUM_TIMEFRAMES tf)
{
   double close1 = iClose(symbol, tf, 1);

   for(int i = 0; i < g_zoneCount; i++)
   {
      if(!g_zones[i].valid) continue;
      if(g_zones[i].zoneType != ZONE_FVG) continue;
      if(g_zones[i].tf != tf) continue;

      // Bullish FVG closed through from above → invert to bearish iFVG
      if(g_zones[i].direction == +1 && close1 < g_zones[i].bottom)
      {
         // Invalidate original FVG
         g_zones[i].valid = false;
         // Create inverted zone (was bullish support → now bearish resistance)
         AddZone(g_zones[i].top, g_zones[i].bottom, -1, ZONE_IFVG, tf, TimeCurrent());
      }

      // Bearish FVG closed through from below → invert to bullish iFVG
      if(g_zones[i].direction == -1 && close1 > g_zones[i].top)
      {
         g_zones[i].valid = false;
         AddZone(g_zones[i].top, g_zones[i].bottom, +1, ZONE_IFVG, tf, TimeCurrent());
      }
   }
}

//+------------------------------------------------------------------+
//| Detect Breaker Blocks                                            |
//| Forms when price breaks through a prior swing high/low           |
//+------------------------------------------------------------------+
void DetectBreakerBlocks(ENUM_TIMEFRAMES tf)
{
   // Find recent swing high and swing low
   double swingHigh = 0, swingLow = 999999;
   int shBar = -1, slBar = -1;

   for(int i = 2; i < SwingLookback + 2; i++)
   {
      double h = iHigh(symbol, tf, i);
      double l = iLow(symbol, tf, i);

      if(h > swingHigh) { swingHigh = h; shBar = i; }
      if(l < swingLow)  { swingLow = l; slBar = i; }
   }

   double close1 = iClose(symbol, tf, 1);
   double close2 = iClose(symbol, tf, 2);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double zoneSize = 10 * point; // Zone size around the broken level

   // Bullish Breaker: price breaks above swing high
   if(close2 <= swingHigh && close1 > swingHigh && shBar > 0)
   {
      AddZone(swingHigh + zoneSize, swingHigh - zoneSize, +1, ZONE_BREAKER, tf, TimeCurrent());
   }

   // Bearish Breaker: price breaks below swing low
   if(close2 >= swingLow && close1 < swingLow && slBar > 0)
   {
      AddZone(swingLow + zoneSize, swingLow - zoneSize, -1, ZONE_BREAKER, tf, TimeCurrent());
   }
}

//+------------------------------------------------------------------+
//| Detect Rejection Blocks                                          |
//| Large body candle closing in top/bottom 25% with big wick        |
//+------------------------------------------------------------------+
void DetectRejectionBlocks(ENUM_TIMEFRAMES tf)
{
   double open1  = iOpen(symbol, tf, 1);
   double close1 = iClose(symbol, tf, 1);
   double high1  = iHigh(symbol, tf, 1);
   double low1   = iLow(symbol, tf, 1);

   double body = MathAbs(close1 - open1);
   double range = high1 - low1;

   if(range <= 0) return;

   // Calculate average body over last 10 bars
   double avgBody = 0;
   for(int i = 2; i <= 11; i++)
   {
      avgBody += MathAbs(iClose(symbol, tf, i) - iOpen(symbol, tf, i));
   }
   avgBody /= 10.0;

   if(avgBody <= 0) return;

   // Check if body is at least 2x average
   if(body < avgBody * RejectionBodyMult) return;

   // Bullish Rejection: closes in top 25% of range → lower wick = support
   double closePosition = (close1 - low1) / range;
   if(close1 > open1 && closePosition >= (1.0 - RejectionCloseZone))
   {
      // Zone = lower wick area
      AddZone(open1, low1, +1, ZONE_REJECTION, tf, TimeCurrent());
   }

   // Bearish Rejection: closes in bottom 25% of range → upper wick = resistance
   if(close1 < open1 && closePosition <= RejectionCloseZone)
   {
      // Zone = upper wick area
      AddZone(high1, open1, -1, ZONE_REJECTION, tf, TimeCurrent());
   }
}

//+------------------------------------------------------------------+
//| Add a zone to the global zone array                              |
//+------------------------------------------------------------------+
void AddZone(double top, double bottom, int direction, int zoneType,
             ENUM_TIMEFRAMES tf, datetime zoneTime)
{
   // Check for duplicate (same level and type)
   for(int i = 0; i < g_zoneCount; i++)
   {
      if(g_zones[i].valid && g_zones[i].tf == tf && g_zones[i].zoneType == zoneType)
      {
         double diff = MathAbs(g_zones[i].top - top) + MathAbs(g_zones[i].bottom - bottom);
         if(diff < SymbolInfoDouble(symbol, SYMBOL_POINT) * 5)
            return; // Duplicate zone
      }
   }

   // Resize if needed
   if(g_zoneCount >= ArraySize(g_zones))
      ArrayResize(g_zones, g_zoneCount + 50);

   g_zones[g_zoneCount].top       = MathMax(top, bottom);
   g_zones[g_zoneCount].bottom    = MathMin(top, bottom);
   g_zones[g_zoneCount].midpoint  = (top + bottom) / 2.0;
   g_zones[g_zoneCount].time      = zoneTime;
   g_zones[g_zoneCount].direction = direction;
   g_zones[g_zoneCount].zoneType  = zoneType;
   g_zones[g_zoneCount].tf        = tf;
   g_zones[g_zoneCount].valid     = true;
   g_zones[g_zoneCount].tested    = false;
   g_zoneCount++;
}

//+------------------------------------------------------------------+
//| Determine HTF bias from Daily and 4H zone direction              |
//+------------------------------------------------------------------+
void DetermineHTFBias()
{
   int bullishWeight = 0;
   int bearishWeight = 0;

   for(int i = 0; i < g_zoneCount; i++)
   {
      if(!g_zones[i].valid) continue;

      int weight = GetTimeframeWeight(g_zones[i].tf);
      if(weight < MinHTFZoneWeight) continue;

      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

      // If price is above a bullish zone → bullish bias
      if(g_zones[i].direction == +1 && bid > g_zones[i].top)
         bullishWeight += weight;
      // If price is below a bearish zone → bearish bias
      else if(g_zones[i].direction == -1 && bid < g_zones[i].bottom)
         bearishWeight += weight;
   }

   if(bullishWeight > bearishWeight)
      g_htfBias = +1;
   else if(bearishWeight > bullishWeight)
      g_htfBias = -1;
   else
      g_htfBias = 0;
}

//+------------------------------------------------------------------+
//| Get weight for a timeframe (per strategy doc)                    |
//+------------------------------------------------------------------+
int GetTimeframeWeight(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_D1:  return 5;  // Highest
      case PERIOD_H4:  return 4;
      case PERIOD_H2:  return 4;
      case PERIOD_H1:  return 3;
      case PERIOD_M30: return 3;
      case PERIOD_M15: return 2;
      case PERIOD_M5:  return 2;  // Lower
      default:         return 1;
   }
}

//+------------------------------------------------------------------+
//| Invalidate zones that price has closed through                   |
//+------------------------------------------------------------------+
void InvalidateZones()
{
   double close1 = iClose(symbol, PERIOD_CURRENT, 1);

   for(int i = 0; i < g_zoneCount; i++)
   {
      if(!g_zones[i].valid) continue;

      // Bullish zone invalidated when candle closes below bottom
      if(g_zones[i].direction == +1 && close1 < g_zones[i].bottom)
         g_zones[i].valid = false;

      // Bearish zone invalidated when candle closes above top
      if(g_zones[i].direction == -1 && close1 > g_zones[i].top)
         g_zones[i].valid = false;
   }
}

//+------------------------------------------------------------------+
//| Check for entry signals — iFVG primary, then supporting zones    |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   // Check position count
   int openCount = CountPositions();
   if(openCount >= MaxActiveTrades)
      return;

   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double close1 = iClose(symbol, PERIOD_CURRENT, 1);
   double close2 = iClose(symbol, PERIOD_CURRENT, 2);

   // Search for best zone to trade (iFVG first, then others)
   int bestZone = -1;
   int bestPriority = 999;

   for(int i = 0; i < g_zoneCount; i++)
   {
      if(!g_zones[i].valid) continue;

      // If strict mode, only trade iFVGs
      if(UseiFVGOnly && g_zones[i].zoneType != ZONE_IFVG)
         continue;

      // Check HTF bias alignment
      if(RequireHTFBias && g_htfBias != 0 && g_zones[i].direction != g_htfBias)
         continue;

      // Priority: iFVG(0) > FVG(1) > Breaker(2) > Rejection(3)
      int priority = g_zones[i].zoneType;

      // Higher timeframe zones get priority boost
      int tfWeight = GetTimeframeWeight(g_zones[i].tf);
      priority = priority * 10 - tfWeight; // Lower = better

      //--- LONG SETUP: price enters bullish zone, candle closes above zone top
      if(g_zones[i].direction == +1)
      {
         // Price was in/below zone on prev bar, now closed above zone top
         bool wasInZone = (close2 <= g_zones[i].top && close2 >= g_zones[i].bottom) ||
                          (close2 < g_zones[i].top);
         bool breakAbove = (close1 > g_zones[i].top);

         if(wasInZone && breakAbove && priority < bestPriority)
         {
            bestZone = i;
            bestPriority = priority;
         }
      }

      //--- SHORT SETUP: price enters bearish zone, candle closes below zone bottom
      if(g_zones[i].direction == -1)
      {
         bool wasInZone = (close2 >= g_zones[i].bottom && close2 <= g_zones[i].top) ||
                          (close2 > g_zones[i].bottom);
         bool breakBelow = (close1 < g_zones[i].bottom);

         if(wasInZone && breakBelow && priority < bestPriority)
         {
            bestZone = i;
            bestPriority = priority;
         }
      }
   }

   //--- Execute the best zone trade
   if(bestZone >= 0)
   {
      if(g_zones[bestZone].direction == +1)
         ExecuteLong(bestZone);
      else
         ExecuteShort(bestZone);
   }
}

//+------------------------------------------------------------------+
//| Execute a LONG trade from a bullish zone                         |
//+------------------------------------------------------------------+
void ExecuteLong(int zoneIdx)
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   //--- Find previous swing low for SL (on execution TF)
   double swingLow = FindSwingLow(SwingLookback);
   if(swingLow <= 0 || swingLow >= ask)
      return;

   double slDistance = ask - swingLow;

   //--- Check if SL is too far (max multiplier of avg range)
   double avgRange = GetAverageRange(20);
   if(avgRange > 0 && slDistance > avgRange * MaxSLMultiplier)
   {
      Print("SKIP LONG: SL too far. Distance=", DoubleToString(slDistance, digits),
            " > ", MaxSLMultiplier, "x avg range=", DoubleToString(avgRange * MaxSLMultiplier, digits));
      return;
   }

   //--- Calculate TP
   double tpPrice = 0.0;
   if(UseStructuralTP)
   {
      double swingHigh = FindSwingHigh(SwingLookback * 2);
      if(swingHigh > ask)
         tpPrice = swingHigh;
   }
   // Fallback to 0.9R
   if(tpPrice == 0.0 || tpPrice <= ask)
      tpPrice = ask + (slDistance * DefaultRR);

   double slPrice = NormalizeDouble(swingLow - 2 * point, digits); // Small buffer below swing
   tpPrice = NormalizeDouble(tpPrice, digits);

   //--- Calculate position size
   double lots = CalculatePositionSize(slDistance);
   if(lots <= 0) return;

   //--- Place order
   string zoneTypeStr = GetZoneTypeName(g_zones[zoneIdx].zoneType);
   string tfStr = EnumToString(g_zones[zoneIdx].tf);
   string comment = StringFormat("LMM BUY %s %s", zoneTypeStr, tfStr);

   if(trade.Buy(lots, symbol, ask, slPrice, tpPrice, comment))
   {
      g_zones[zoneIdx].tested = true;
      Print("LONG ENTRY: ", comment,
            " | Price=", DoubleToString(ask, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2),
            " | Zone=[", DoubleToString(g_zones[zoneIdx].bottom, digits),
            "-", DoubleToString(g_zones[zoneIdx].top, digits), "]");
   }
   else
   {
      Print("LONG FAILED: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute a SHORT trade from a bearish zone                        |
//+------------------------------------------------------------------+
void ExecuteShort(int zoneIdx)
{
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   //--- Find previous swing high for SL
   double swingHigh = FindSwingHigh(SwingLookback);
   if(swingHigh <= 0 || swingHigh <= bid)
      return;

   double slDistance = swingHigh - bid;

   //--- Check if SL is too far
   double avgRange = GetAverageRange(20);
   if(avgRange > 0 && slDistance > avgRange * MaxSLMultiplier)
   {
      Print("SKIP SHORT: SL too far.");
      return;
   }

   //--- Calculate TP
   double tpPrice = 0.0;
   if(UseStructuralTP)
   {
      double swingLow = FindSwingLow(SwingLookback * 2);
      if(swingLow < bid && swingLow > 0)
         tpPrice = swingLow;
   }
   if(tpPrice == 0.0 || tpPrice >= bid)
      tpPrice = bid - (slDistance * DefaultRR);

   double slPrice = NormalizeDouble(swingHigh + 2 * point, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   //--- Calculate position size
   double lots = CalculatePositionSize(slDistance);
   if(lots <= 0) return;

   //--- Place order
   string zoneTypeStr = GetZoneTypeName(g_zones[zoneIdx].zoneType);
   string tfStr = EnumToString(g_zones[zoneIdx].tf);
   string comment = StringFormat("LMM SELL %s %s", zoneTypeStr, tfStr);

   if(trade.Sell(lots, symbol, bid, slPrice, tpPrice, comment))
   {
      g_zones[zoneIdx].tested = true;
      Print("SHORT ENTRY: ", comment,
            " | Price=", DoubleToString(bid, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2));
   }
   else
   {
      Print("SHORT FAILED: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Calculate position size from dollar risk and SL distance         |
//| Contracts = Dollar Risk / (SL Distance in Points * Point Value)  |
//+------------------------------------------------------------------+
double CalculatePositionSize(double slDistancePrice)
{
   if(DollarRisk <= 0)
      return ValidateLotSize(FixedLotSize);

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) return ValidateLotSize(FixedLotSize);

   double slPoints = slDistancePrice / point;

   if(slPoints <= 0 || PointValue <= 0)
      return ValidateLotSize(FixedLotSize);

   // For futures: contracts = risk / (points * point_value)
   // For forex: use tick value approach
   double lots = 0;

   if(PointValue > 0)
   {
      lots = DollarRisk / (slPoints * PointValue);
   }
   else
   {
      // Forex fallback
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0 && tickSize > 0)
      {
         double slTicks = slDistancePrice / tickSize;
         lots = DollarRisk / (slTicks * tickValue);
      }
   }

   return ValidateLotSize(lots);
}

//+------------------------------------------------------------------+
//| Validate lot size against broker limits                          |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0)
      return 0.01;

   double lots = MathFloor(requestedLots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Find swing low in the last N bars                                |
//+------------------------------------------------------------------+
double FindSwingLow(int lookback)
{
   double lowest = iLow(symbol, PERIOD_CURRENT, 1);
   for(int i = 2; i <= lookback; i++)
   {
      double l = iLow(symbol, PERIOD_CURRENT, i);
      if(l < lowest) lowest = l;
   }
   return lowest;
}

//+------------------------------------------------------------------+
//| Find swing high in the last N bars                               |
//+------------------------------------------------------------------+
double FindSwingHigh(int lookback)
{
   double highest = iHigh(symbol, PERIOD_CURRENT, 1);
   for(int i = 2; i <= lookback; i++)
   {
      double h = iHigh(symbol, PERIOD_CURRENT, i);
      if(h > highest) highest = h;
   }
   return highest;
}

//+------------------------------------------------------------------+
//| Get average bar range over last N bars                           |
//+------------------------------------------------------------------+
double GetAverageRange(int bars)
{
   double total = 0;
   for(int i = 1; i <= bars; i++)
   {
      total += iHigh(symbol, PERIOD_CURRENT, i) - iLow(symbol, PERIOD_CURRENT, i);
   }
   return (bars > 0) ? total / bars : 0;
}

//+------------------------------------------------------------------+
//| Manage breakeven — move SL to entry + buffer at 1R profit        |
//+------------------------------------------------------------------+
void ManageBreakeven()
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == "" || posSymbol == NULL) continue;
      if(posSymbol != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      int posType = (int)PositionGetInteger(POSITION_TYPE);

      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

      if(posType == POSITION_TYPE_BUY)
      {
         double initialRisk = openPrice - currentSL;
         if(initialRisk <= 0) continue;

         // Move to breakeven when price has moved 1R in favour
         if(bid >= openPrice + initialRisk)
         {
            double newSL = NormalizeDouble(openPrice + BreakevenBuffer * point, digits);
            if(newSL > currentSL)
               trade.PositionModify(ticket, newSL, currentTP);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double initialRisk = currentSL - openPrice;
         if(initialRisk <= 0) continue;

         if(ask <= openPrice - initialRisk)
         {
            double newSL = NormalizeDouble(openPrice - BreakevenBuffer * point, digits);
            if(newSL < currentSL || currentSL == 0)
               trade.PositionModify(ticket, newSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                 |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == "" || posSymbol == NULL) continue;
      if(posSymbol != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get zone type name for logging                                   |
//+------------------------------------------------------------------+
string GetZoneTypeName(int zoneType)
{
   switch(zoneType)
   {
      case ZONE_FVG:       return "FVG";
      case ZONE_IFVG:      return "iFVG";
      case ZONE_BREAKER:   return "Breaker";
      case ZONE_REJECTION: return "Rejection";
      default:             return "Unknown";
   }
}
//+------------------------------------------------------------------+

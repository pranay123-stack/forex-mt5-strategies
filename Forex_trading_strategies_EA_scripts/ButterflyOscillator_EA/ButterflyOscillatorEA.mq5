//+------------------------------------------------------------------+
//| ButterflyOscillatorEA.mq5                                         |
//| Butterfly Oscillator Trading Strategy                             |
//| Dual MA trend filter + Butterfly Curve peak/trough entries       |
//+------------------------------------------------------------------+
#property strict
#property copyright "Butterfly Oscillator EA"
#property version   "1.00"
#property description "Butterfly Curve oscillator with dual SMA trend filter"
#property description "Strategy 1: Peak (+2.5 crossover), Strategy 2: Trough (-2.5 crossover)"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters - Oscillator Settings                           |
//+------------------------------------------------------------------+
input group "=== Butterfly Oscillator Settings ==="
input bool     UsePriceStep     = false;     // Use Close-Open price difference as step size
input double   tmStep           = 0.05;      // Fixed step size for t increment

//+------------------------------------------------------------------+
//| Input Parameters - Strategy Selection                            |
//+------------------------------------------------------------------+
input group "=== Strategy Selection ==="
input bool     EnableStrategy1  = true;      // Enable Strategy 1 (Peak, upper threshold +2.5)
input bool     EnableStrategy2  = false;     // Enable Strategy 2 (Trough, lower threshold -2.5)

//+------------------------------------------------------------------+
//| Input Parameters - Trend Filter (Dual MA)                        |
//+------------------------------------------------------------------+
input group "=== Trend Filter (Dual SMA) ==="
input int      FastMAPeriod     = 50;        // Fast Moving Average Period
input int      SlowMAPeriod     = 200;       // Slow Moving Average Period

//+------------------------------------------------------------------+
//| Input Parameters - Trade Settings                                |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double   LotSize          = 0.1;       // Lot Size
input int      StopLoss         = 500;       // Stop Loss in points (0 = disabled)
input int      TakeProfit       = 1000;      // Take Profit in points (0 = disabled)
input int      MagicNumber      = 123456;    // Magic Number

//+------------------------------------------------------------------+
//| Input Parameters - Display                                       |
//+------------------------------------------------------------------+
input group "=== Display ==="
input bool     ShowOscillatorInfo = true;    // Show Oscillator & MA info on chart

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define UPPER_THRESHOLD  2.5    // Peak threshold for Strategy 1
#define LOWER_THRESHOLD -2.5    // Trough threshold for Strategy 2

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;

// Indicator handles for moving averages
int fastMAHandle;
int slowMAHandle;

// Oscillator state
double curOsc;
double prevOsc;

// Running bar counter — increments each new bar so oscillator cycles properly
int barCounter;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Input validation
   if(tmStep <= 0.0)
   {
      Print("ERROR: tmStep must be > 0. Got: ", tmStep);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastMAPeriod <= 0 || SlowMAPeriod <= 0)
   {
      Print("ERROR: MA periods must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastMAPeriod >= SlowMAPeriod)
   {
      Print("WARNING: FastMAPeriod (", FastMAPeriod, ") >= SlowMAPeriod (", SlowMAPeriod,
            "). Trend filter may not work as expected.");
   }

   if(LotSize <= 0.0)
   {
      Print("ERROR: LotSize must be > 0. Got: ", LotSize);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!EnableStrategy1 && !EnableStrategy2)
   {
      Print("WARNING: Both strategies are disabled. No trades will be placed.");
   }

   //--- Create MA indicator handles
   fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, FastMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(fastMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Fast MA handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(slowMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Slow MA handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   //--- Initialize state
   curOsc = 0.0;
   prevOsc = 0.0;
   barCounter = 0;

   //--- Set up trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Print startup info
   Print("============================================");
   Print("Butterfly Oscillator EA v1.00 Initialized");
   Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(Period()));
   Print("Step Mode: ", UsePriceStep ? "Price-Based" : "Fixed");
   Print("tmStep: ", tmStep);
   Print("Strategy 1 (Peak +2.5): ", EnableStrategy1 ? "ENABLED" : "DISABLED");
   Print("Strategy 2 (Trough -2.5): ", EnableStrategy2 ? "ENABLED" : "DISABLED");
   Print("Fast MA: ", FastMAPeriod, " | Slow MA: ", SlowMAPeriod);
   Print("Lot Size: ", LotSize);
   Print("SL: ", StopLoss, " pts", (StopLoss == 0 ? " (disabled)" : ""),
         " | TP: ", TakeProfit, " pts", (TakeProfit == 0 ? " (disabled)" : ""));
   Print("Account Balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
   Print("============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE)
      IndicatorRelease(fastMAHandle);

   if(slowMAHandle != INVALID_HANDLE)
      IndicatorRelease(slowMAHandle);

   // Clear chart comment
   Comment("");

   Print("Butterfly Oscillator EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process on new bar
   if(!IsNewBar())
      return;

   //--- Increment running bar counter
   barCounter++;

   //--- Calculate oscillator using running bar counter
   // barCounter grows over time so t sweeps through the butterfly curve
   // Previous bar uses barCounter-1, current bar uses barCounter
   prevOsc = CalButterflyValue(barCounter - 1, iClose(_Symbol, PERIOD_CURRENT, 2), iOpen(_Symbol, PERIOD_CURRENT, 2));
   curOsc  = CalButterflyValue(barCounter,     iClose(_Symbol, PERIOD_CURRENT, 1), iOpen(_Symbol, PERIOD_CURRENT, 1));

   //--- Get MA values for trend determination
   double fastMA[1], slowMA[1];
   if(CopyBuffer(fastMAHandle, 0, 1, 1, fastMA) <= 0) return;
   if(CopyBuffer(slowMAHandle, 0, 1, 1, slowMA) <= 0) return;

   bool isUptrend   = (fastMA[0] > slowMA[0]);
   bool isDowntrend = (fastMA[0] < slowMA[0]);

   //--- Display oscillator info on chart
   if(ShowOscillatorInfo)
   {
      string trendStr = isUptrend ? "UPTREND" : (isDowntrend ? "DOWNTREND" : "NEUTRAL");
      Comment(StringFormat(
         "Butterfly Oscillator EA\n"
         "─────────────────────\n"
         "Current Osc:  %.4f\n"
         "Previous Osc: %.4f\n"
         "Fast MA(%d):  %.5f\n"
         "Slow MA(%d):  %.5f\n"
         "Trend: %s\n"
         "─────────────────────\n"
         "Strategy 1 (Peak +2.5): %s\n"
         "Strategy 2 (Trough -2.5): %s",
         curOsc, prevOsc,
         FastMAPeriod, fastMA[0],
         SlowMAPeriod, slowMA[0],
         trendStr,
         EnableStrategy1 ? "ON" : "OFF",
         EnableStrategy2 ? "ON" : "OFF"
      ));
   }

   //--- Skip if already have an open position
   if(HasOpenPosition())
      return;

   //--- Check entry signals
   CheckEntrySignals(isUptrend, isDowntrend);
}

//+------------------------------------------------------------------+
//| Detect new bar formation                                         |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Butterfly Oscillator value for a given bar             |
//|                                                                  |
//| Butterfly Curve x-component:                                     |
//|   x = sin(t) * (e^cos(t) - 2*cos(4t) - sin(t/12)^5)            |
//|                                                                  |
//| Where t = bar_index * tStep                                      |
//|   Fixed mode: tStep = tmStep                                     |
//|   Price mode: tStep = MathMod((close-open)/_Point, tmStep)       |
//+------------------------------------------------------------------+
double CalButterflyValue(int bar_index, double bar_close, double bar_open)
{
   //--- Calculate the step size based on mode
   double tStep = 0.0;

   if(UsePriceStep)
   {
      // Price-based step: use the close-open difference in points, modulo tmStep
      double priceDiff = (bar_close - bar_open) / _Point;
      tStep = MathMod(priceDiff, tmStep);

      // Handle case where MathMod returns 0 (exact multiple or zero diff)
      if(MathAbs(tStep) < 1e-10)
         tStep = tmStep * 0.01; // Small non-zero value to avoid stale oscillator
   }
   else
   {
      // Fixed step mode
      tStep = tmStep;
   }

   //--- Calculate t = bar_index * tStep
   double t = (double)bar_index * tStep;

   //--- Calculate Butterfly Curve x-component
   // x = sin(t) * (e^cos(t) - 2*cos(4t) - sin(t/12)^5)
   double sinT = MathSin(t);
   double eCosT = MathExp(MathCos(t));
   double cos4T = MathCos(4.0 * t);
   double sinT12 = MathSin(t / 12.0);
   double sinT12_pow5 = sinT12 * sinT12 * sinT12 * sinT12 * sinT12; // sin(t/12)^5

   double result = sinT * (eCosT - 2.0 * cos4T - sinT12_pow5);

   return result;
}

//+------------------------------------------------------------------+
//| Check if we have an open position with our magic number          |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == "" || posSymbol == NULL)
         continue;

      if(posSymbol != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check entry signals for both strategies                          |
//+------------------------------------------------------------------+
void CheckEntrySignals(bool isUptrend, bool isDowntrend)
{
   //--- Strategy 1: Peak — oscillator crosses above +2.5
   if(EnableStrategy1)
   {
      bool peakCrossover = (prevOsc < UPPER_THRESHOLD) && (curOsc >= UPPER_THRESHOLD);

      if(peakCrossover)
      {
         if(isUptrend)
         {
            // Peak crossover in uptrend → BUY
            if(OpenBuy())
            {
               Print("STRATEGY 1 (Peak): BUY in UPTREND",
                     " | Osc crossed above +", UPPER_THRESHOLD,
                     " | curOsc=", DoubleToString(curOsc, 4),
                     " | prevOsc=", DoubleToString(prevOsc, 4));
            }
            return; // First triggered strategy takes priority
         }
         else if(isDowntrend)
         {
            // Peak crossover in downtrend → SELL
            if(OpenSell())
            {
               Print("STRATEGY 1 (Peak): SELL in DOWNTREND",
                     " | Osc crossed above +", UPPER_THRESHOLD,
                     " | curOsc=", DoubleToString(curOsc, 4),
                     " | prevOsc=", DoubleToString(prevOsc, 4));
            }
            return;
         }
      }
   }

   //--- Strategy 2: Trough — oscillator crosses below -2.5
   if(EnableStrategy2)
   {
      bool troughCrossover = (prevOsc > LOWER_THRESHOLD) && (curOsc <= LOWER_THRESHOLD);

      if(troughCrossover)
      {
         if(isUptrend)
         {
            // Trough crossover in uptrend → BUY
            if(OpenBuy())
            {
               Print("STRATEGY 2 (Trough): BUY in UPTREND",
                     " | Osc crossed below ", LOWER_THRESHOLD,
                     " | curOsc=", DoubleToString(curOsc, 4),
                     " | prevOsc=", DoubleToString(prevOsc, 4));
            }
            return;
         }
         else if(isDowntrend)
         {
            // Trough crossover in downtrend → SELL
            if(OpenSell())
            {
               Print("STRATEGY 2 (Trough): SELL in DOWNTREND",
                     " | Osc crossed below ", LOWER_THRESHOLD,
                     " | curOsc=", DoubleToString(curOsc, 4),
                     " | prevOsc=", DoubleToString(prevOsc, 4));
            }
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open a BUY position with SL/TP in points                        |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0)
   {
      Print("ERROR: Invalid ASK price");
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- Calculate SL and TP in price (points directly)
   double slPrice = 0.0;
   double tpPrice = 0.0;

   if(StopLoss > 0)
      slPrice = NormalizeDouble(ask - StopLoss * point, digits);

   if(TakeProfit > 0)
      tpPrice = NormalizeDouble(ask + TakeProfit * point, digits);

   //--- Check broker's minimum stop distance
   if(StopLoss > 0 || TakeProfit > 0)
   {
      int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      if(stopsLevel > 0)
      {
         double minDist = stopsLevel * point;

         if(StopLoss > 0 && (ask - slPrice) < minDist)
            slPrice = NormalizeDouble(ask - minDist - point, digits);

         if(TakeProfit > 0 && (tpPrice - ask) < minDist)
            tpPrice = NormalizeDouble(ask + minDist + point, digits);
      }
   }

   //--- Validate lot size
   double lots = ValidateLotSize(LotSize);
   if(lots <= 0.0)
      return false;

   //--- Place BUY order
   if(trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, "Butterfly BUY"))
   {
      Print("BUY OPENED: Price=", DoubleToString(ask, digits),
            " | SL=", (StopLoss > 0 ? DoubleToString(slPrice, digits) : "none"),
            " | TP=", (TakeProfit > 0 ? DoubleToString(tpPrice, digits) : "none"),
            " | Lots=", DoubleToString(lots, 2),
            " | Osc=", DoubleToString(curOsc, 4));
      return true;
   }
   else
   {
      Print("BUY FAILED: Error=", trade.ResultRetcode(),
            " - ", trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open a SELL position with SL/TP in points                        |
//+------------------------------------------------------------------+
bool OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0)
   {
      Print("ERROR: Invalid BID price");
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- Calculate SL and TP in price (points directly)
   double slPrice = 0.0;
   double tpPrice = 0.0;

   if(StopLoss > 0)
      slPrice = NormalizeDouble(bid + StopLoss * point, digits);

   if(TakeProfit > 0)
      tpPrice = NormalizeDouble(bid - TakeProfit * point, digits);

   //--- Check broker's minimum stop distance
   if(StopLoss > 0 || TakeProfit > 0)
   {
      int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      if(stopsLevel > 0)
      {
         double minDist = stopsLevel * point;

         if(StopLoss > 0 && (slPrice - bid) < minDist)
            slPrice = NormalizeDouble(bid + minDist + point, digits);

         if(TakeProfit > 0 && (bid - tpPrice) < minDist)
            tpPrice = NormalizeDouble(bid - minDist - point, digits);
      }
   }

   //--- Validate lot size
   double lots = ValidateLotSize(LotSize);
   if(lots <= 0.0)
      return false;

   //--- Place SELL order
   if(trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, "Butterfly SELL"))
   {
      Print("SELL OPENED: Price=", DoubleToString(bid, digits),
            " | SL=", (StopLoss > 0 ? DoubleToString(slPrice, digits) : "none"),
            " | TP=", (TakeProfit > 0 ? DoubleToString(tpPrice, digits) : "none"),
            " | Lots=", DoubleToString(lots, 2),
            " | Osc=", DoubleToString(curOsc, 4));
      return true;
   }
   else
   {
      Print("SELL FAILED: Error=", trade.ResultRetcode(),
            " - ", trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Validate and clamp lot size to broker limits                     |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0 || maxLot <= 0.0 || lotStep <= 0.0)
   {
      Print("ERROR: Invalid volume info. Min=", minLot, " Max=", maxLot, " Step=", lotStep);
      return -1.0;
   }

   double lots = MathFloor(requestedLots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+

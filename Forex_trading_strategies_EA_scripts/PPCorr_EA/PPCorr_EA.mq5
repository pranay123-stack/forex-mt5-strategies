//+------------------------------------------------------------------+
//| PPCorr_EA.mq5                                                     |
//| Pseudo Pearson Correlation Trading Strategy                       |
//| PPC computed inline (no external indicator dependency)            |
//| Dual EMA trend filter                                             |
//+------------------------------------------------------------------+
#property strict
#property copyright "PPCorr Strategy EA"
#property version   "1.10"
#property description "Pseudo Pearson Correlation of DeMarker/MFI/RSI"
#property description "Strategy 1: Correlated Momentum (+PPr crossover)"
#property description "Strategy 2: Non-Correlated (-PPr crossunder)"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters - Trade Settings                                |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double   Lots           = 0.01;      // Lot Size
input int      StopLoss       = 300;       // Stop Loss (points)
input int      TakeProfit     = 700;       // Take Profit (points)
input int      Slippage       = 3;         // Slippage (points)
input int      MagicNumber    = 77889900;  // Magic Number

//+------------------------------------------------------------------+
//| Input Parameters - PseudoPC Settings                             |
//+------------------------------------------------------------------+
input group "=== PseudoPC Correlation ==="
input int      CorrPeriod     = 21;        // Correlation Lookback Period
input int      RSIPeriod      = 14;        // RSI Period
input int      MFIPeriod      = 14;        // MFI Period
input int      DeMPeriod      = 14;        // DeMarker Period

//+------------------------------------------------------------------+
//| Input Parameters - Strategy Settings                             |
//+------------------------------------------------------------------+
input group "=== Strategy Settings ==="
input double   PPr            = 0.5;       // Correlation Threshold (0.1 to 1.0)
input bool     EnableStrategy1 = true;     // Strategy 1: Correlated Momentum (+PPr crossover)
input bool     EnableStrategy2 = false;    // Strategy 2: Non-Correlated (-PPr crossunder)

//+------------------------------------------------------------------+
//| Input Parameters - Trend Filter (Dual EMA)                       |
//+------------------------------------------------------------------+
input group "=== Trend Filter (Dual EMA) ==="
input int      FastMAPeriod   = 2;         // Fast EMA Period
input int      SlowMAPeriod   = 20;        // Slow EMA Period

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;

// Indicator handles for inline PPC calculation
int rsiHandle;
int mfiHandle;
int demHandle;
int fastMAHandle;
int slowMAHandle;

// PPC state
double corr_curr;
double corr_prev;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Input validation
   if(PPr < 0.1 || PPr > 1.0)
   {
      Print("ERROR: PPr must be between 0.1 and 1.0. Got: ", PPr);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(CorrPeriod <= 1 || RSIPeriod <= 0 || MFIPeriod <= 0 || DeMPeriod <= 0)
   {
      Print("ERROR: All indicator periods must be > 0 (CorrPeriod > 1).");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FastMAPeriod <= 0 || SlowMAPeriod <= 0)
   {
      Print("ERROR: MA periods must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(Lots <= 0.0)
   {
      Print("ERROR: Lots must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Create indicator handles for PPC calculation
   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create RSI handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   mfiHandle = iMFI(_Symbol, PERIOD_CURRENT, MFIPeriod, VOLUME_TICK);
   if(mfiHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MFI handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   demHandle = iDeMarker(_Symbol, PERIOD_CURRENT, DeMPeriod);
   if(demHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create DeMarker handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   //--- Create EMA handles for trend filter
   fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(fastMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Fast EMA handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(slowMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Slow EMA handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   //--- Initialize state
   corr_curr = 0.0;
   corr_prev = 0.0;

   //--- Set up trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Print startup info
   Print("============================================");
   Print("PPCorr EA v1.10 Initialized (inline PPC)");
   Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(Period()));
   Print("PseudoPC: Corr=", CorrPeriod, " RSI=", RSIPeriod,
         " MFI=", MFIPeriod, " DeM=", DeMPeriod);
   Print("Threshold PPr: +/-", PPr);
   Print("Strategy 1 (Correlated Momentum): ", EnableStrategy1 ? "ON" : "OFF");
   Print("Strategy 2 (Non-Correlated): ", EnableStrategy2 ? "ON" : "OFF");
   Print("Fast EMA: ", FastMAPeriod, " | Slow EMA: ", SlowMAPeriod);
   Print("Lots: ", Lots, " | SL: ", StopLoss, " pts | TP: ", TakeProfit, " pts");
   Print("Account Balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
   Print("============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)     IndicatorRelease(rsiHandle);
   if(mfiHandle != INVALID_HANDLE)     IndicatorRelease(mfiHandle);
   if(demHandle != INVALID_HANDLE)     IndicatorRelease(demHandle);
   if(fastMAHandle != INVALID_HANDLE)  IndicatorRelease(fastMAHandle);
   if(slowMAHandle != INVALID_HANDLE)  IndicatorRelease(slowMAHandle);

   Print("PPCorr EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process on new bar
   if(!IsNewBar())
      return;

   //--- Calculate PPC inline for bar[1] (current) and bar[2] (previous)
   if(!CalculatePPC())
      return;

   //--- Read Fast EMA and Slow EMA for bar[1]
   double fastMA[1], slowMA[1];
   if(CopyBuffer(fastMAHandle, 0, 1, 1, fastMA) < 1) return;
   if(CopyBuffer(slowMAHandle, 0, 1, 1, slowMA) < 1) return;

   bool isBullish = (fastMA[0] > slowMA[0]);
   bool isBearish = (fastMA[0] < slowMA[0]);

   //--- Check if we already have an open position
   if(HasOpenPosition())
      return;

   //--- STRATEGY 1: Correlated Momentum
   // PPC crosses ABOVE +PPr → momentum aligned
   if(EnableStrategy1)
   {
      bool crossAbove = (corr_prev < PPr) && (corr_curr >= PPr);

      if(crossAbove)
      {
         if(isBullish)
         {
            if(OpenTrade(ORDER_TYPE_BUY, "Strategy1 BUY"))
               Print("S1: BUY | PPC=", DoubleToString(corr_curr, 4), " crossed +", PPr);
            return;
         }
         else if(isBearish)
         {
            if(OpenTrade(ORDER_TYPE_SELL, "Strategy1 SELL"))
               Print("S1: SELL | PPC=", DoubleToString(corr_curr, 4), " crossed +", PPr);
            return;
         }
      }
   }

   //--- STRATEGY 2: Non-Correlated
   // PPC crosses BELOW -PPr → divergence
   if(EnableStrategy2)
   {
      bool crossBelow = (corr_prev > -PPr) && (corr_curr <= -PPr);

      if(crossBelow)
      {
         if(isBullish)
         {
            if(OpenTrade(ORDER_TYPE_BUY, "Strategy2 BUY"))
               Print("S2: BUY | PPC=", DoubleToString(corr_curr, 4), " crossed -", PPr);
            return;
         }
         else if(isBearish)
         {
            if(OpenTrade(ORDER_TYPE_SELL, "Strategy2 SELL"))
               Print("S2: SELL | PPC=", DoubleToString(corr_curr, 4), " crossed -", PPr);
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Pseudo Pearson Correlation inline                      |
//| Computes PPC for bar[1] (current) and bar[2] (previous)         |
//|                                                                  |
//| x = DeMarker, y = MFI/100, z = RSI/100 (baseline)               |
//| dx = x - z, dy = y - z                                          |
//| r' = sum(dx*dy) / sqrt(sum(dx^2) * sum(dy^2))                   |
//+------------------------------------------------------------------+
bool CalculatePPC()
{
   //--- We need CorrPeriod bars of RSI, MFI, DeMarker starting from bar[1] and bar[2]
   int dataNeeded = CorrPeriod + 2;

   double rsiData[];
   double mfiData[];
   double demData[];

   if(CopyBuffer(rsiHandle, 0, 1, dataNeeded, rsiData) < dataNeeded) return false;
   if(CopyBuffer(mfiHandle, 0, 1, dataNeeded, mfiData) < dataNeeded) return false;
   if(CopyBuffer(demHandle, 0, 1, dataNeeded, demData) < dataNeeded) return false;

   // rsiData[dataNeeded-1] = bar[1] (most recent closed)
   // rsiData[dataNeeded-2] = bar[2] (previous closed)

   //--- Calculate PPC for bar[1] (current)
   corr_curr = ComputePPC(rsiData, mfiData, demData, dataNeeded - 1);

   //--- Calculate PPC for bar[2] (previous)
   corr_prev = ComputePPC(rsiData, mfiData, demData, dataNeeded - 2);

   return true;
}

//+------------------------------------------------------------------+
//| Compute PPC for a specific position in the data arrays           |
//+------------------------------------------------------------------+
double ComputePPC(const double &rsi[], const double &mfi[], const double &dem[], int endIdx)
{
   double sum_xy = 0.0;
   double sum_x2 = 0.0;
   double sum_y2 = 0.0;

   for(int j = 0; j < CorrPeriod; j++)
   {
      int idx = endIdx - j;
      if(idx < 0) break;

      double x = dem[idx];            // DeMarker (0-1)
      double y = mfi[idx] / 100.0;    // MFI normalized to 0-1
      double z = rsi[idx] / 100.0;    // RSI normalized to 0-1 (baseline)

      double dx = x - z;
      double dy = y - z;

      sum_xy += dx * dy;
      sum_x2 += dx * dx;
      sum_y2 += dy * dy;
   }

   double denominator = MathSqrt(sum_x2 * sum_y2);

   if(denominator <= 0.0)
      return 0.0; // No variance — return neutral

   double r = sum_xy / denominator;
   return MathMax(-1.0, MathMin(1.0, r));
}

//+------------------------------------------------------------------+
//| Detect new bar formation                                         |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBar != lastBar)
   {
      lastBar = currentBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if an open position exists for this symbol and magic       |
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
//| Open a trade (BUY or SELL) with SL/TP in points                  |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType, string comment)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double price = 0.0;
   double slPrice = 0.0;
   double tpPrice = 0.0;

   if(orderType == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(price <= 0.0) { Print("ERROR: Invalid ASK"); return false; }

      if(StopLoss > 0)   slPrice = NormalizeDouble(price - StopLoss * point, digits);
      if(TakeProfit > 0)  tpPrice = NormalizeDouble(price + TakeProfit * point, digits);
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(price <= 0.0) { Print("ERROR: Invalid BID"); return false; }

      if(StopLoss > 0)   slPrice = NormalizeDouble(price + StopLoss * point, digits);
      if(TakeProfit > 0)  tpPrice = NormalizeDouble(price - TakeProfit * point, digits);
   }

   //--- Check minimum stop distance
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel > 0)
   {
      double minDist = stopsLevel * point;
      if(orderType == ORDER_TYPE_BUY)
      {
         if(StopLoss > 0 && (price - slPrice) < minDist)
            slPrice = NormalizeDouble(price - minDist - point, digits);
         if(TakeProfit > 0 && (tpPrice - price) < minDist)
            tpPrice = NormalizeDouble(price + minDist + point, digits);
      }
      else
      {
         if(StopLoss > 0 && (slPrice - price) < minDist)
            slPrice = NormalizeDouble(price + minDist + point, digits);
         if(TakeProfit > 0 && (price - tpPrice) < minDist)
            tpPrice = NormalizeDouble(price - minDist - point, digits);
      }
   }

   //--- Validate lot size
   double lots = ValidateLotSize(Lots);
   if(lots <= 0.0) return false;

   //--- Execute
   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(lots, _Symbol, price, slPrice, tpPrice, comment);
   else
      result = trade.Sell(lots, _Symbol, price, slPrice, tpPrice, comment);

   if(result)
   {
      Print((orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " OPENED @ ", DoubleToString(price, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | ", comment);
      return true;
   }
   else
   {
      Print("ORDER FAILED: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
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
      Print("ERROR: Invalid volume info.");
      return -1.0;
   }

   double lots = MathFloor(requestedLots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+

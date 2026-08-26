//+------------------------------------------------------------------+
//| VB_EA.mq5                                                         |
//| Volume Boundary Oscillator (VBO) Trading Strategy                 |
//| Butterfly Curve / Triple Sine volume-based entries                |
//+------------------------------------------------------------------+
#property strict
#property copyright "VBO Strategy EA"
#property version   "1.00"
#property description "Volume Boundary Oscillator with Butterfly/TripleSine smoothing"
#property description "Threshold crossover entries with price action confirmation"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_INPUT_METHOD
{
   scaledMethod = 0,    // Scaled (Z-Score)
   logMethod    = 1     // Logarithmic
};

enum ENUM_SMOOTHING_METHOD
{
   ButterflyCurve = 0,  // Butterfly Curve (range ~+/-3)
   TripleSine     = 1   // Triple Sine (range +/-1)
};

//+------------------------------------------------------------------+
//| Input Parameters - VBO Indicator Settings                        |
//+------------------------------------------------------------------+
input group "=== VBO Indicator Settings ==="
input int                   VolumePeriod    = 20;              // Volume Lookback Period
input double                ScaleFactor     = 1.0;             // Scale Factor Multiplier
input ENUM_INPUT_METHOD     InputMethod     = scaledMethod;    // Transformation Method
input ENUM_SMOOTHING_METHOD SmoothingMethod = ButterflyCurve;  // Smoothing Function

//+------------------------------------------------------------------+
//| Input Parameters - Trade Settings                                |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double   LotSize          = 0.1;         // Lot Size
input double   BuyThreshold     = 0.5;         // VBO Buy Threshold
input double   SellThreshold    = -0.5;        // VBO Sell Threshold
input int      TakeProfit       = 100;         // Take Profit (pips)
input int      StopLoss         = 50;          // Stop Loss (pips)
input int      MagicNumber      = 20250101;    // Magic Number
input string   TradeComment     = "VBO_EA";    // Trade Comment

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;

// VBO state — current and previous bar values
double curVBO;
double prevVBO;

// Multiple entry tracking
// For alternating threshold logic:
//   firstBuyThresholdWasNegative = true if the first buy triggered at a negative threshold
//   This means the second buy should trigger at a positive threshold, and vice versa
bool   firstBuyOpen;
bool   firstBuyThresholdWasNegative;
bool   firstSellOpen;
bool   firstSellThresholdWasNegative;

// Pip multiplier for 4-digit vs 5-digit brokers
double pipMultiplier;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Input validation
   if(VolumePeriod <= 1)
   {
      Print("ERROR: VolumePeriod must be > 1. Got: ", VolumePeriod);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ScaleFactor <= 0.0)
   {
      Print("ERROR: ScaleFactor must be > 0. Got: ", ScaleFactor);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(LotSize <= 0.0)
   {
      Print("ERROR: LotSize must be > 0. Got: ", LotSize);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(TakeProfit <= 0 || StopLoss <= 0)
   {
      Print("ERROR: TakeProfit and StopLoss must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Determine pip multiplier (5-digit vs 4-digit broker)
   if(_Digits == 5 || _Digits == 3)
      pipMultiplier = 10.0;
   else
      pipMultiplier = 1.0;

   //--- Initialize state
   curVBO = 0.0;
   prevVBO = 0.0;
   firstBuyOpen = false;
   firstBuyThresholdWasNegative = false;
   firstSellOpen = false;
   firstSellThresholdWasNegative = false;

   //--- Set up trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Print startup info
   Print("============================================");
   Print("VB_EA (Volume Boundary Oscillator) v1.00 Initialized");
   Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(Period()));
   Print("Volume Period: ", VolumePeriod, " | Scale Factor: ", ScaleFactor);
   Print("Input Method: ", InputMethod == scaledMethod ? "Scaled (Z-Score)" : "Logarithmic");
   Print("Smoothing: ", SmoothingMethod == ButterflyCurve ? "Butterfly Curve" : "Triple Sine");
   Print("Buy Threshold: ", BuyThreshold, " | Sell Threshold: ", SellThreshold);
   Print("SL: ", StopLoss, " pips | TP: ", TakeProfit, " pips");
   Print("Lot Size: ", LotSize, " | Max 2 buys + 2 sells");
   Print("Pip Multiplier: ", pipMultiplier, " (", _Digits, "-digit broker)");
   Print("Account Balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
   Print("============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("VB_EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process on new bar
   if(!IsNewBar())
      return;

   //--- Calculate VBO for the last closed bar
   if(!CalculateVBO())
      return;

   //--- Sync position tracking state with actual open positions
   SyncPositionState();

   //--- Check for entry signals
   CheckEntryConditions();
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
//| Calculate the Volume Boundary Oscillator (VBO)                   |
//|                                                                  |
//| Step 1: Compute volume statistics (mean, stddev)                 |
//| Step 2: Scale volume into t (Z-score or log method)              |
//| Step 3: Apply smoothing function (Butterfly or Triple Sine)      |
//+------------------------------------------------------------------+
bool CalculateVBO()
{
   //--- Shift current to previous
   prevVBO = curVBO;

   //--- Get tick volume data for the last VolumePeriod bars (starting from bar[1])
   long volumeBuffer[];
   ArrayResize(volumeBuffer, VolumePeriod);

   if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 1, VolumePeriod, volumeBuffer) < VolumePeriod)
   {
      Print("WARNING: Failed to copy tick volume. Error: ", GetLastError());
      return false;
   }

   //--- Step 1: Compute volume statistics over VolumePeriod bars
   double sumVol = 0.0;
   double sumVolSq = 0.0;

   for(int i = 0; i < VolumePeriod; i++)
   {
      double vol = (double)volumeBuffer[i];
      sumVol += vol;
      sumVolSq += vol * vol;
   }

   double avgVol = sumVol / (double)VolumePeriod;

   // Population standard deviation: sqrt(E[X^2] - E[X]^2)
   double variance = (sumVolSq / (double)VolumePeriod) - (avgVol * avgVol);

   // Guard against negative variance from floating point errors
   double stdVol = 0.0;
   if(variance > 0.0)
      stdVol = MathSqrt(variance);

   //--- Current volume is the most recent bar in the buffer (last element)
   double currentVolume = (double)volumeBuffer[VolumePeriod - 1];

   //--- Step 2: Scale volume into t based on selected method
   double t = 0.0;

   if(InputMethod == scaledMethod)
   {
      // Z-Score method: t = ScaleFactor * (currentVolume - AvgVol) / StdVol
      if(stdVol <= 0.0)
      {
         // Zero standard deviation = all volumes identical, no signal
         curVBO = 0.0;
         return true;
      }
      t = ScaleFactor * (currentVolume - avgVol) / stdVol;
   }
   else // logMethod
   {
      // Logarithmic method: t = ScaleFactor * log(currentVolume)
      if(currentVolume <= 0.0)
      {
         // Zero volume, no signal
         curVBO = 0.0;
         return true;
      }
      t = ScaleFactor * MathLog(currentVolume);
   }

   //--- Step 3: Apply smoothing function to produce VBO value
   if(SmoothingMethod == ButterflyCurve)
   {
      // Butterfly Curve (range approximately ±3.0):
      // f(t) = sin(t) * (e^cos(t) - 2*cos(4t) - sin(t/12)^5)
      double sinT = MathSin(t);
      double eCosT = MathExp(MathCos(t));
      double cos4T = MathCos(4.0 * t);
      double sinT12 = MathSin(t / 12.0);
      double sinT12_pow5 = sinT12 * sinT12 * sinT12 * sinT12 * sinT12; // sin(t/12)^5

      curVBO = sinT * (eCosT - 2.0 * cos4T - sinT12_pow5);
   }
   else // TripleSine
   {
      // Triple Sine (range ±1.0):
      // f(t) = sin(t)^3
      double sinT = MathSin(t);
      curVBO = sinT * sinT * sinT; // Preserves sign
   }

   return true;
}

//+------------------------------------------------------------------+
//| Synchronize internal tracking state with actual open positions   |
//| This ensures state is correct even after EA restart or manual    |
//| intervention                                                     |
//+------------------------------------------------------------------+
void SyncPositionState()
{
   int buyCount = 0;
   int sellCount = 0;
   CountPositions(buyCount, sellCount);

   // If no buy positions open, reset buy tracking
   if(buyCount == 0)
   {
      firstBuyOpen = false;
      firstBuyThresholdWasNegative = false;
   }
   else if(buyCount >= 1)
   {
      firstBuyOpen = true;
   }

   // If no sell positions open, reset sell tracking
   if(sellCount == 0)
   {
      firstSellOpen = false;
      firstSellThresholdWasNegative = false;
   }
   else if(sellCount >= 1)
   {
      firstSellOpen = true;
   }
}

//+------------------------------------------------------------------+
//| Check entry conditions and execute trades                        |
//+------------------------------------------------------------------+
void CheckEntryConditions()
{
   //--- Count current open positions
   int buyCount = 0;
   int sellCount = 0;
   CountPositions(buyCount, sellCount);

   //--- Get price action data for bar[1] (last closed candle)
   double open1  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   bool isBullishCandle = (close1 > open1);
   bool isBearishCandle = (close1 < open1);

   //--- BUY SIGNAL: VBO crosses above BuyThreshold
   bool buyCrossover = (prevVBO < BuyThreshold) && (curVBO >= BuyThreshold);

   //--- SELL SIGNAL: VBO crosses below SellThreshold
   bool sellCrossover = (prevVBO > SellThreshold) && (curVBO <= SellThreshold);

   //=== BUY LOGIC ===

   // First BUY entry: requires price action confirmation + threshold crossover
   if(buyCrossover && buyCount == 0 && buyCount + sellCount < 2)
   {
      if(isBullishCandle)
      {
         if(OpenBuyPosition())
         {
            firstBuyOpen = true;
            // Track whether this first buy was triggered at a negative threshold level
            firstBuyThresholdWasNegative = (BuyThreshold < 0.0);
            Print("FIRST BUY: VBO crossed above ", BuyThreshold,
                  " | VBO=", DoubleToString(curVBO, 4),
                  " | Bullish candle confirmed");
         }
      }
   }
   // Second BUY entry: alternating threshold, no price action required
   // If first buy was at negative threshold → second triggers at positive threshold
   // If first buy was at positive threshold → second triggers at negative threshold
   else if(buyCount == 1 && buyCount + sellCount < 2)
   {
      bool secondBuyTrigger = false;

      if(firstBuyThresholdWasNegative)
      {
         // First was negative, second needs positive crossover
         // VBO crosses above the absolute (positive) threshold
         secondBuyTrigger = (prevVBO < MathAbs(BuyThreshold)) && (curVBO >= MathAbs(BuyThreshold));
      }
      else
      {
         // First was positive, second needs negative crossover
         // VBO crosses above the negative threshold (coming from even lower)
         secondBuyTrigger = (prevVBO < -MathAbs(BuyThreshold)) && (curVBO >= -MathAbs(BuyThreshold));
      }

      if(secondBuyTrigger)
      {
         if(OpenBuyPosition())
         {
            Print("SECOND BUY (alternating threshold): VBO=", DoubleToString(curVBO, 4),
                  " | No price action required");
         }
      }
   }

   //=== SELL LOGIC ===

   // First SELL entry: requires price action confirmation + threshold crossover
   if(sellCrossover && sellCount == 0 && buyCount + sellCount < 2)
   {
      if(isBearishCandle)
      {
         if(OpenSellPosition())
         {
            firstSellOpen = true;
            // Track whether this first sell was triggered at a positive threshold level
            firstSellThresholdWasNegative = (SellThreshold < 0.0);
            Print("FIRST SELL: VBO crossed below ", SellThreshold,
                  " | VBO=", DoubleToString(curVBO, 4),
                  " | Bearish candle confirmed");
         }
      }
   }
   // Second SELL entry: alternating threshold, no price action required
   else if(sellCount == 1 && buyCount + sellCount < 2)
   {
      bool secondSellTrigger = false;

      if(firstSellThresholdWasNegative)
      {
         // First sell was at negative threshold, second needs positive
         // VBO crosses below the positive threshold (coming from higher)
         secondSellTrigger = (prevVBO > MathAbs(SellThreshold)) && (curVBO <= MathAbs(SellThreshold));
      }
      else
      {
         // First sell was at positive threshold, second needs negative
         // VBO crosses below the negative threshold
         secondSellTrigger = (prevVBO > -MathAbs(SellThreshold)) && (curVBO <= -MathAbs(SellThreshold));
      }

      if(secondSellTrigger)
      {
         if(OpenSellPosition())
         {
            Print("SECOND SELL (alternating threshold): VBO=", DoubleToString(curVBO, 4),
                  " | No price action required");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count open BUY and SELL positions for this EA                    |
//+------------------------------------------------------------------+
void CountPositions(int &buyCount, int &sellCount)
{
   buyCount = 0;
   sellCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == "" || posSymbol == NULL)
         continue;

      if(posSymbol != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
         buyCount++;
      else if(posType == POSITION_TYPE_SELL)
         sellCount++;
   }
}

//+------------------------------------------------------------------+
//| Open a BUY market order with SL and TP in pips                   |
//+------------------------------------------------------------------+
bool OpenBuyPosition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0)
   {
      Print("ERROR: Invalid ASK price");
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- Calculate SL and TP in price (pips → points → price)
   double slPrice = NormalizeDouble(ask - StopLoss * pipMultiplier * point, digits);
   double tpPrice = NormalizeDouble(ask + TakeProfit * pipMultiplier * point, digits);

   //--- Check broker's minimum stop distance
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel > 0)
   {
      double minDist = stopsLevel * point;
      if((ask - slPrice) < minDist)
         slPrice = NormalizeDouble(ask - minDist - point, digits);
      if((tpPrice - ask) < minDist)
         tpPrice = NormalizeDouble(ask + minDist + point, digits);
   }

   //--- Validate lot size
   double lots = ValidateLotSize(LotSize);
   if(lots <= 0.0)
      return false;

   //--- Place BUY order
   if(trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, TradeComment))
   {
      Print("BUY OPENED: Price=", DoubleToString(ask, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2),
            " | VBO=", DoubleToString(curVBO, 4));
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
//| Open a SELL market order with SL and TP in pips                  |
//+------------------------------------------------------------------+
bool OpenSellPosition()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0)
   {
      Print("ERROR: Invalid BID price");
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- Calculate SL and TP in price (pips → points → price)
   double slPrice = NormalizeDouble(bid + StopLoss * pipMultiplier * point, digits);
   double tpPrice = NormalizeDouble(bid - TakeProfit * pipMultiplier * point, digits);

   //--- Check broker's minimum stop distance
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel > 0)
   {
      double minDist = stopsLevel * point;
      if((slPrice - bid) < minDist)
         slPrice = NormalizeDouble(bid + minDist + point, digits);
      if((bid - tpPrice) < minDist)
         tpPrice = NormalizeDouble(bid - minDist - point, digits);
   }

   //--- Validate lot size
   double lots = ValidateLotSize(LotSize);
   if(lots <= 0.0)
      return false;

   //--- Place SELL order
   if(trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, TradeComment))
   {
      Print("SELL OPENED: Price=", DoubleToString(bid, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2),
            " | VBO=", DoubleToString(curVBO, 4));
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

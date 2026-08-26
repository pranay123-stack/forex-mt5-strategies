//+------------------------------------------------------------------+
//| TSO_MeanReversion_EA.mq5                                          |
//| Triple Sine Oscillator Mean Reversion Expert Advisor              |
//| Sine-cubed Z-score oscillator with directional exclusivity       |
//+------------------------------------------------------------------+
#property strict
#property copyright "TSO Mean Reversion EA"
#property version   "1.00"
#property description "Triple Sine Mean Reversion Strategy"
#property description "TSO = sin^3(k*(Close-MA)/StdDev), bounded [-1,+1]"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters - TSO Indicator Settings                        |
//+------------------------------------------------------------------+
input group "=== TSO Indicator Settings ==="
input int      mPeriod          = 20;        // SMA & StdDev Lookback Period
input double   Ksense           = 0.5;       // Sensitivity Multiplier
input double   TSO_Threshold    = 0.7;       // Overbought/Oversold Threshold

//+------------------------------------------------------------------+
//| Input Parameters - Trade Settings                                |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input int      TakeProfit       = 200;       // Take Profit (points)
input int      StopLoss         = 100;       // Stop Loss (points)
input double   LotSize          = 0.1;       // Lot Size
input int      MaxEntries       = 5;         // Max Open Positions
input int      BarInterval      = 10;        // Min Bars Between Entries
input int      MagicNumber      = 12345;     // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;

// Indicator handles
int maHandle;
int stdDevHandle;

// TSO state
double curTSO;
double prevTSO;

// Bar tracking for cooldown
int barsSinceLastEntry;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Input validation
   if(mPeriod <= 1)
   {
      Print("ERROR: mPeriod must be > 1. Got: ", mPeriod);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(Ksense <= 0.0)
   {
      Print("ERROR: Ksense must be > 0. Got: ", Ksense);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(TSO_Threshold <= 0.0 || TSO_Threshold > 1.0)
   {
      Print("ERROR: TSO_Threshold must be in (0, 1.0]. Got: ", TSO_Threshold);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(TakeProfit <= 0 || StopLoss <= 0)
   {
      Print("ERROR: TakeProfit and StopLoss must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(LotSize <= 0.0)
   {
      Print("ERROR: LotSize must be > 0. Got: ", LotSize);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxEntries <= 0)
   {
      Print("ERROR: MaxEntries must be > 0. Got: ", MaxEntries);
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Create indicator handles
   maHandle = iMA(_Symbol, PERIOD_CURRENT, mPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create SMA handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   stdDevHandle = iStdDev(_Symbol, PERIOD_CURRENT, mPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(stdDevHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create StdDev handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   //--- Initialize state
   curTSO = 0.0;
   prevTSO = 0.0;
   barsSinceLastEntry = BarInterval; // Allow trading immediately on start

   //--- Set up trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Print startup info
   Print("============================================");
   Print("TSO Mean Reversion EA v1.00 Initialized");
   Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(Period()));
   Print("mPeriod: ", mPeriod, " | Ksense: ", Ksense);
   Print("TSO Threshold: +/-", TSO_Threshold);
   Print("SL: ", StopLoss, " pts | TP: ", TakeProfit, " pts");
   Print("Lot Size: ", LotSize, " | Max Entries: ", MaxEntries);
   Print("Bar Interval: ", BarInterval);
   Print("Account Balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
   Print("============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(maHandle != INVALID_HANDLE)
      IndicatorRelease(maHandle);

   if(stdDevHandle != INVALID_HANDLE)
      IndicatorRelease(stdDevHandle);

   Print("TSO Mean Reversion EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process on new bar
   if(!IsNewBar())
      return;

   //--- Increment bar counter
   barsSinceLastEntry++;

   //--- Calculate TSO for last closed bar
   if(!CalculateTSO())
      return;

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
//| Calculate the Triple Sine Oscillator (TSO)                       |
//|                                                                  |
//| Formula:                                                         |
//|   scaled = Ksense * (Close - SMA) / StdDev                      |
//|   TSO = sin(scaled)^3 = MathPow(MathSin(scaled), 3)             |
//|                                                                  |
//| Result is bounded in [-1, +1]                                    |
//| > +TSO_Threshold = overbought                                    |
//| < -TSO_Threshold = oversold                                      |
//+------------------------------------------------------------------+
bool CalculateTSO()
{
   //--- Shift current to previous
   prevTSO = curTSO;

   //--- Get close price of last closed bar (bar[1])
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close <= 0.0)
   {
      Print("WARNING: Invalid close price for bar[1]");
      return false;
   }

   //--- Get SMA value for bar[1]
   double maBuffer[1];
   if(CopyBuffer(maHandle, 0, 1, 1, maBuffer) <= 0)
   {
      Print("WARNING: Failed to copy SMA buffer. Error: ", GetLastError());
      return false;
   }
   double ma = maBuffer[0];

   //--- Get StdDev value for bar[1]
   double stdBuffer[1];
   if(CopyBuffer(stdDevHandle, 0, 1, 1, stdBuffer) <= 0)
   {
      Print("WARNING: Failed to copy StdDev buffer. Error: ", GetLastError());
      return false;
   }
   double stdDev = stdBuffer[0];

   //--- Guard against division by zero (StdDev = 0 means flat market)
   if(stdDev <= 0.0 || stdDev < _Point)
   {
      curTSO = 0.0;
      return true;
   }

   //--- Step 1: Compute scaled Z-score
   // How far price is from the mean, normalized by volatility, scaled by sensitivity
   double scaled = Ksense * (close - ma) / stdDev;

   //--- Step 2: Apply sine cube function → TSO = sin(scaled)^3
   // The sine function compresses any input to [-1, +1]
   // Cubing it amplifies values near the extremes and dampens mid-range noise
   double sinVal = MathSin(scaled);
   curTSO = sinVal * sinVal * sinVal; // sin^3 = sin * sin * sin (preserves sign)

   //--- Clamp for safety (should already be bounded)
   curTSO = MathMax(-1.0, MathMin(1.0, curTSO));

   return true;
}

//+------------------------------------------------------------------+
//| Check entry conditions and execute trades                        |
//+------------------------------------------------------------------+
void CheckEntryConditions()
{
   //--- Count current positions
   int buyCount = 0;
   int sellCount = 0;
   CountPositions(buyCount, sellCount);
   int totalPositions = buyCount + sellCount;

   //--- Check max entries limit
   if(totalPositions >= MaxEntries)
      return;

   //--- BUY SIGNAL: TSO crosses below oversold threshold
   // Previous TSO was above -threshold, current TSO dropped below -threshold
   // Meaning: price just became oversold → expect mean reversion upward
   bool buySignal = (prevTSO > -TSO_Threshold) && (curTSO <= -TSO_Threshold);

   //--- SELL SIGNAL: TSO crosses above overbought threshold
   // Previous TSO was below +threshold, current TSO rose above +threshold
   // Meaning: price just became overbought → expect mean reversion downward
   bool sellSignal = (prevTSO < TSO_Threshold) && (curTSO >= TSO_Threshold);

   //--- Execute BUY
   if(buySignal && CanOpenBuy(sellCount))
   {
      if(OpenBuyPosition())
      {
         barsSinceLastEntry = 0;
         Print("BUY SIGNAL FIRED: TSO crossed below -", TSO_Threshold,
               " | curTSO=", DoubleToString(curTSO, 4),
               " | prevTSO=", DoubleToString(prevTSO, 4));
      }
   }

   //--- Execute SELL
   if(sellSignal && CanOpenSell(buyCount))
   {
      if(OpenSellPosition())
      {
         barsSinceLastEntry = 0;
         Print("SELL SIGNAL FIRED: TSO crossed above +", TSO_Threshold,
               " | curTSO=", DoubleToString(curTSO, 4),
               " | prevTSO=", DoubleToString(prevTSO, 4));
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
//| Check if a BUY position can be opened                            |
//| Rules:                                                           |
//|   1. No SELL positions open (directional exclusivity)            |
//|   2. Bar interval cooldown elapsed                               |
//+------------------------------------------------------------------+
bool CanOpenBuy(int sellCount)
{
   // Directional exclusivity: no sells allowed when opening a buy
   if(sellCount > 0)
   {
      Print("BUY blocked: ", sellCount, " SELL position(s) still open. Directional exclusivity.");
      return false;
   }

   // Bar interval cooldown
   if(barsSinceLastEntry < BarInterval)
   {
      Print("BUY blocked: cooldown. Bars since last entry: ", barsSinceLastEntry, "/", BarInterval);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check if a SELL position can be opened                           |
//| Rules:                                                           |
//|   1. No BUY positions open (directional exclusivity)             |
//|   2. Bar interval cooldown elapsed                               |
//+------------------------------------------------------------------+
bool CanOpenSell(int buyCount)
{
   // Directional exclusivity: no buys allowed when opening a sell
   if(buyCount > 0)
   {
      Print("SELL blocked: ", buyCount, " BUY position(s) still open. Directional exclusivity.");
      return false;
   }

   // Bar interval cooldown
   if(barsSinceLastEntry < BarInterval)
   {
      Print("SELL blocked: cooldown. Bars since last entry: ", barsSinceLastEntry, "/", BarInterval);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Open a BUY market order with SL and TP in points                 |
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

   //--- Calculate SL and TP in price (points directly, no pip conversion)
   double slPrice = NormalizeDouble(ask - StopLoss * point, digits);
   double tpPrice = NormalizeDouble(ask + TakeProfit * point, digits);

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
   if(trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, "TSO BUY"))
   {
      Print("BUY OPENED: Price=", DoubleToString(ask, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2),
            " | TSO=", DoubleToString(curTSO, 4));
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
//| Open a SELL market order with SL and TP in points                |
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

   //--- Calculate SL and TP in price (points directly)
   double slPrice = NormalizeDouble(bid + StopLoss * point, digits);
   double tpPrice = NormalizeDouble(bid - TakeProfit * point, digits);

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
   if(trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, "TSO SELL"))
   {
      Print("SELL OPENED: Price=", DoubleToString(bid, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2),
            " | TSO=", DoubleToString(curTSO, 4));
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

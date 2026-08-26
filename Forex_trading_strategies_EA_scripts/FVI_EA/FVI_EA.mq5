//+------------------------------------------------------------------+
//| FVI_EA.mq5                                                        |
//| Flower Volatility Index (FVI) Trend-Following Expert Advisor      |
//| Based on Rose Curve mathematics with AO trend filter              |
//+------------------------------------------------------------------+
#property strict
#property copyright "FVI Strategy EA"
#property version   "1.00"
#property description "Flower Volatility Index trend-following EA"
#property description "Uses Rose Curve derived oscillator with Awesome Oscillator filter"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters - FVI Indicator Settings                        |
//+------------------------------------------------------------------+
input group "=== FVI Indicator Settings ==="
input int      MA_Period        = 14;       // Moving Average Period
input int      ATR_Period       = 14;       // ATR Period
input int      n_param          = 5;        // Rose Curve Numerator (n)
input int      d_param          = 1;        // Rose Curve Denominator (d)
input double   k_sensitivity    = 1.0;      // Sensitivity Scalar (k)
input bool     Use_X_Component  = true;     // true = X-component, false = Y-component

//+------------------------------------------------------------------+
//| Input Parameters - Trade Settings                                |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double   LotSize          = 0.1;      // Trade Lot Size
input double   StopLoss_Pips    = 50.0;     // Stop Loss (pips)
input double   TakeProfit_Pips  = 100.0;    // Take Profit (pips)
input int      MinBarsBtwEntries = 10;      // Cooldown Bars Between Entries
input double   FVI_Threshold    = 0.7;      // FVI Threshold for Signal
input int      MagicNumber      = 123456;   // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;

// Indicator handles
int maHandle;
int atrHandle;
int aoHandle;

// FVI state
double curFVI;
double prevFVI;

// Cooldown counter
int barsSinceLastTrade;

// Pip multiplier (handles 4-digit and 5-digit brokers)
double pipMultiplier;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Input validation
   if(d_param == 0)
   {
      Print("ERROR: d_param (Rose Curve denominator) cannot be 0. Division by zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MA_Period <= 0)
   {
      Print("ERROR: MA_Period must be > 0. Got: ", MA_Period);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ATR_Period <= 0)
   {
      Print("ERROR: ATR_Period must be > 0. Got: ", ATR_Period);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(LotSize <= 0)
   {
      Print("ERROR: LotSize must be > 0. Got: ", LotSize);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(StopLoss_Pips <= 0 || TakeProfit_Pips <= 0)
   {
      Print("ERROR: StopLoss_Pips and TakeProfit_Pips must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(FVI_Threshold <= 0 || FVI_Threshold > 1.0)
   {
      Print("ERROR: FVI_Threshold must be in (0, 1.0]. Got: ", FVI_Threshold);
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Determine pip multiplier for 4-digit vs 5-digit brokers
   // 5-digit brokers (EURUSD: 1.12345) → 1 pip = 10 points
   // 4-digit brokers (EURUSD: 1.1234)  → 1 pip = 1 point
   // 3-digit brokers (USDJPY: 112.345) → 1 pip = 10 points
   // 2-digit brokers (USDJPY: 112.34)  → 1 pip = 1 point
   if(_Digits == 5 || _Digits == 3)
      pipMultiplier = 10.0;
   else
      pipMultiplier = 1.0;

   //--- Create indicator handles
   maHandle = iMA(_Symbol, PERIOD_CURRENT, MA_Period, 0, MODE_SMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA indicator handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   // Awesome Oscillator uses default periods (5 SMA and 34 SMA of bar midpoints)
   aoHandle = iAO(_Symbol, PERIOD_CURRENT);
   if(aoHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create AO indicator handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   //--- Initialize state
   curFVI = 0.0;
   prevFVI = 0.0;
   barsSinceLastTrade = MinBarsBtwEntries; // Allow trading immediately on start

   //--- Set up trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Print startup info
   Print("============================================");
   Print("FVI EA v1.00 Initialized");
   Print("Symbol: ", _Symbol, " | Timeframe: ", EnumToString(Period()));
   Print("MA Period: ", MA_Period, " | ATR Period: ", ATR_Period);
   Print("Rose Curve: n=", n_param, ", d=", d_param);
   Print("Sensitivity (k): ", k_sensitivity);
   Print("Component: ", Use_X_Component ? "X (r*cos)" : "Y (r*sin)");
   Print("FVI Threshold: ", FVI_Threshold);
   Print("Lot Size: ", LotSize);
   Print("SL: ", StopLoss_Pips, " pips | TP: ", TakeProfit_Pips, " pips");
   Print("Cooldown: ", MinBarsBtwEntries, " bars");
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
   //--- Release all indicator handles
   if(maHandle != INVALID_HANDLE)
      IndicatorRelease(maHandle);

   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   if(aoHandle != INVALID_HANDLE)
      IndicatorRelease(aoHandle);

   Print("FVI EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process on new bar (avoid recalculating every tick)
   if(!IsNewBar())
      return;

   //--- Increment cooldown counter
   barsSinceLastTrade++;

   //--- Calculate FVI for the last closed bar
   if(!CalculateFVI())
      return;

   //--- Check for entry signals
   CheckForEntry();
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
//| Calculate the Flower Volatility Index (FVI)                      |
//|                                                                  |
//| FVI is derived from the Rose Curve:                              |
//|   q = k * (Close - MA) / ATR                                    |
//|   r = sin(n * q / (2 * d))                                      |
//|   FVI_X = r * cos(q)   (X-component)                            |
//|   FVI_Y = r * sin(q)   (Y-component)                            |
//|                                                                  |
//| Result is bounded in [-1, +1]                                    |
//+------------------------------------------------------------------+
bool CalculateFVI()
{
   //--- Shift current FVI to previous
   prevFVI = curFVI;

   //--- Get close price of last closed bar (bar index 1)
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close <= 0)
   {
      Print("WARNING: Invalid close price for bar[1]");
      return false;
   }

   //--- Get MA value for bar[1]
   double maBuffer[1];
   if(CopyBuffer(maHandle, 0, 1, 1, maBuffer) <= 0)
   {
      Print("WARNING: Failed to copy MA buffer. Error: ", GetLastError());
      return false;
   }
   double ma = maBuffer[0];

   //--- Get ATR value for bar[1]
   double atrBuffer[1];
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0)
   {
      Print("WARNING: Failed to copy ATR buffer. Error: ", GetLastError());
      return false;
   }
   double atr = atrBuffer[0];

   //--- Guard against division by zero (ATR = 0 means no volatility)
   if(atr <= 0.0 || atr < _Point)
   {
      curFVI = 0.0;
      return true;
   }

   //--- Step 1: Compute the market-derived angle q
   // q represents normalized price deviation from the mean, scaled by volatility
   double q = k_sensitivity * (close - ma) / atr;

   //--- Step 2: Compute the radial component r from the Rose Curve
   // r = sin(n * q / (2 * d))
   double roseArg = ((double)n_param * q) / (2.0 * (double)d_param);
   double r = MathSin(roseArg);

   //--- Step 3: Compute FVI based on selected component
   if(Use_X_Component)
   {
      // X-component: FVI = r * cos(q)
      curFVI = r * MathCos(q);
   }
   else
   {
      // Y-component: FVI = r * sin(q)
      curFVI = r * MathSin(q);
   }

   //--- Clamp to [-1, +1] for safety (should already be bounded)
   curFVI = MathMax(-1.0, MathMin(1.0, curFVI));

   return true;
}

//+------------------------------------------------------------------+
//| Check for entry signals and execute trades                       |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   //--- Check cooldown period
   if(barsSinceLastTrade < MinBarsBtwEntries)
      return;

   //--- Get Awesome Oscillator value for bar[1]
   double aoBuffer[1];
   if(CopyBuffer(aoHandle, 0, 1, 1, aoBuffer) <= 0)
   {
      Print("WARNING: Failed to copy AO buffer. Error: ", GetLastError());
      return;
   }
   double aoValue = aoBuffer[0];

   //--- BUY SIGNAL ---
   // Conditions:
   //   1. AO > 0 (uptrend confirmed by Awesome Oscillator)
   //   2. Previous FVI was above -FVI_Threshold (not yet in oversold zone)
   //   3. Current FVI crossed below -FVI_Threshold (entered oversold zone)
   //   4. No existing BUY position open for this EA
   bool buySignal = (aoValue > 0.0)
                    && (prevFVI > -FVI_Threshold)
                    && (curFVI <= -FVI_Threshold)
                    && (CountPositions(POSITION_TYPE_BUY) == 0);

   //--- SELL SIGNAL ---
   // Conditions:
   //   1. AO < 0 (downtrend confirmed by Awesome Oscillator)
   //   2. Previous FVI was below +FVI_Threshold (not yet in overbought zone)
   //   3. Current FVI crossed above +FVI_Threshold (entered overbought zone)
   //   4. No existing SELL position open for this EA
   bool sellSignal = (aoValue < 0.0)
                     && (prevFVI < FVI_Threshold)
                     && (curFVI >= FVI_Threshold)
                     && (CountPositions(POSITION_TYPE_SELL) == 0);

   //--- Execute BUY order
   if(buySignal)
   {
      if(OpenBuyOrder())
      {
         barsSinceLastTrade = 0; // Reset cooldown
         Print("BUY SIGNAL: FVI crossed below -", FVI_Threshold,
               " | FVI: ", DoubleToString(curFVI, 4),
               " | prevFVI: ", DoubleToString(prevFVI, 4),
               " | AO: ", DoubleToString(aoValue, 5));
      }
   }

   //--- Execute SELL order
   if(sellSignal)
   {
      if(OpenSellOrder())
      {
         barsSinceLastTrade = 0; // Reset cooldown
         Print("SELL SIGNAL: FVI crossed above +", FVI_Threshold,
               " | FVI: ", DoubleToString(curFVI, 4),
               " | prevFVI: ", DoubleToString(prevFVI, 4),
               " | AO: ", DoubleToString(aoValue, 5));
      }
   }
}

//+------------------------------------------------------------------+
//| Open a BUY market order with SL and TP                           |
//+------------------------------------------------------------------+
bool OpenBuyOrder()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0)
   {
      Print("ERROR: Invalid ASK price");
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- Calculate SL and TP in price
   // For 5-digit broker: 50 pips = 50 * 10 * point = 500 points
   double slPrice = ask - StopLoss_Pips * pipMultiplier * point;
   double tpPrice = ask + TakeProfit_Pips * pipMultiplier * point;

   //--- Normalize to symbol digits
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   //--- Check broker's minimum stop distance
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevel * point;

   if((ask - slPrice) < minStopDistance)
   {
      Print("WARNING: SL too close. Adjusting to minimum stop distance.");
      slPrice = NormalizeDouble(ask - minStopDistance - point, digits);
   }

   if((tpPrice - ask) < minStopDistance)
   {
      Print("WARNING: TP too close. Adjusting to minimum stop distance.");
      tpPrice = NormalizeDouble(ask + minStopDistance + point, digits);
   }

   //--- Validate lot size against broker limits
   double lots = ValidateLotSize(LotSize);
   if(lots <= 0)
      return false;

   //--- Place BUY order
   if(trade.Buy(lots, _Symbol, ask, slPrice, tpPrice, "FVI BUY"))
   {
      Print("BUY ORDER OPENED: Price=", DoubleToString(ask, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2));
      return true;
   }
   else
   {
      Print("BUY ORDER FAILED: Error=", trade.ResultRetcode(),
            " - ", trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open a SELL market order with SL and TP                          |
//+------------------------------------------------------------------+
bool OpenSellOrder()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0)
   {
      Print("ERROR: Invalid BID price");
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- Calculate SL and TP in price
   double slPrice = bid + StopLoss_Pips * pipMultiplier * point;
   double tpPrice = bid - TakeProfit_Pips * pipMultiplier * point;

   //--- Normalize to symbol digits
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   //--- Check broker's minimum stop distance
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevel * point;

   if((slPrice - bid) < minStopDistance)
   {
      Print("WARNING: SL too close. Adjusting to minimum stop distance.");
      slPrice = NormalizeDouble(bid + minStopDistance + point, digits);
   }

   if((bid - tpPrice) < minStopDistance)
   {
      Print("WARNING: TP too close. Adjusting to minimum stop distance.");
      tpPrice = NormalizeDouble(bid - minStopDistance - point, digits);
   }

   //--- Validate lot size against broker limits
   double lots = ValidateLotSize(LotSize);
   if(lots <= 0)
      return false;

   //--- Place SELL order
   if(trade.Sell(lots, _Symbol, bid, slPrice, tpPrice, "FVI SELL"))
   {
      Print("SELL ORDER OPENED: Price=", DoubleToString(bid, digits),
            " | SL=", DoubleToString(slPrice, digits),
            " | TP=", DoubleToString(tpPrice, digits),
            " | Lots=", DoubleToString(lots, 2));
      return true;
   }
   else
   {
      Print("SELL ORDER FAILED: Error=", trade.ResultRetcode(),
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

   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0)
   {
      Print("ERROR: Invalid symbol volume info. Min=", minLot,
            " Max=", maxLot, " Step=", lotStep);
      return -1.0;
   }

   //--- Round to lot step
   double lots = MathFloor(requestedLots / lotStep) * lotStep;

   //--- Clamp to min/max
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Count open positions of a given type for this EA                 |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE posType)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      // Select position by index — PositionGetSymbol returns "" on failure
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == "" || posSymbol == NULL)
         continue;

      // Check if this position belongs to our EA (magic number) and symbol
      if(posSymbol != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         count++;
   }

   return count;
}
//+------------------------------------------------------------------+

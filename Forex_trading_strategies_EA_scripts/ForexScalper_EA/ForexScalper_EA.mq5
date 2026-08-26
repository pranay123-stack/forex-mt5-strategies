//+------------------------------------------------------------------+
//| ForexScalper_EA.mq5                                               |
//| Forex Scalping EA V2 - Multi-Confluence Pullback Scalper          |
//| EMA Trend + Pullback Entry + RSI/MACD/Volume Confirmation        |
//| H1 ATR Stops + Spread Filter + Partial Close + Signal Quality    |
//+------------------------------------------------------------------+
#property strict
#property copyright "ForexScalper EA V3"
#property version   "3.00"
#property description "Pullback-based Forex scalping with multi-confluence"
#property description "H1 ATR dynamic stops, spread filter, partial close at 1R"
#property description "Minimum signal strength gate for high-quality entries"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_SIGNAL_MODE
{
   MODE_AGGRESSIVE   = 0,  // Aggressive (more signals)
   MODE_BALANCED     = 1,  // Balanced
   MODE_CONSERVATIVE = 2   // Conservative (fewer signals)
};

enum ENUM_SL_MODE
{
   SL_ATR_BASED = 0,   // ATR-Based Dynamic Stop (H1 ATR)
   SL_FIXED     = 1    // Fixed Pip Stop
};

//+------------------------------------------------------------------+
//| Input Parameters - Signal Engine                                 |
//+------------------------------------------------------------------+
input group "=== Signal Engine ==="
input ENUM_SIGNAL_MODE SignalMode       = MODE_BALANCED;  // Signal Mode
input int     MinSignalStrength         = 2;              // Minimum Signal Strength (1-7)
input bool    FilterByHTFTrend          = true;           // Filter by Higher TF Trend
input ENUM_TIMEFRAMES  HTF_Timeframe    = PERIOD_H1;      // Higher TF for Trend
input bool    RequireVolumeConfirm      = false;          // Require Volume Confirmation
input double  VolumeMultiplier          = 1.1;            // Volume Threshold (x average)

//+------------------------------------------------------------------+
//| Input Parameters - EMA Settings                                  |
//+------------------------------------------------------------------+
input group "=== EMA Settings ==="
input int     EMA_Fast_Period           = 9;              // Fast EMA Period
input int     EMA_Slow_Period           = 21;             // Slow EMA Period
input int     EMA_Trend_Period          = 50;             // Trend EMA Period (structure)

//+------------------------------------------------------------------+
//| Input Parameters - Momentum Filters                              |
//+------------------------------------------------------------------+
input group "=== Momentum Filters ==="
input int     RSI_Period                = 14;             // RSI Period
input bool    UseRSIFilter              = true;           // Enable RSI Filter
input int     MACD_Fast                 = 12;             // MACD Fast
input int     MACD_Slow                 = 26;             // MACD Slow
input int     MACD_Signal               = 9;              // MACD Signal
input bool    UseMACDFilter             = true;           // Enable MACD Filter

//+------------------------------------------------------------------+
//| Input Parameters - Risk Management                               |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double  RiskPercent               = 1.0;            // Risk Per Trade (% of balance)
input double  FixedLotSize              = 0.1;            // Fixed Lot (if RiskPercent=0)
input double  RR_Ratio                  = 2.0;            // Reward:Risk Ratio
input int     MaxActiveTrades           = 1;              // Max Simultaneous Trades
input int     MaxDailyTrades            = 10;             // Max Trades Per Day (0=unlimited)
input int     MaxDailyLosses            = 3;              // Max Losses Per Day (0=unlimited)

//+------------------------------------------------------------------+
//| Input Parameters - Stop Loss / Take Profit                       |
//+------------------------------------------------------------------+
input group "=== Stop Loss & Take Profit ==="
input ENUM_SL_MODE SL_Mode              = SL_ATR_BASED;   // Stop Loss Mode
input int     ATR_Period                = 14;              // ATR Period (calculated on H1)
input double  ATR_SL_Multiplier         = 1.5;            // ATR SL Multiplier
input double  FixedSL_Pips              = 12.0;           // Fixed SL (pips) if Fixed mode
input double  MinSL_Pips                = 5.0;            // Minimum SL (pips)
input double  MaxSL_Pips                = 30.0;           // Maximum SL (pips)
input bool    UsePartialClose           = true;           // Close 50% at 1R Profit
input bool    UseBreakeven              = true;           // Move SL to BE after partial close
input double  BreakevenBufferPips       = 0.5;            // Breakeven Buffer (pips)
input bool    UseTrailingStop           = true;            // Enable Trailing Stop (after 1R)
input double  TrailingATR_Mult          = 1.0;            // Trailing Stop ATR Multiplier

//+------------------------------------------------------------------+
//| Input Parameters - Spread Filter                                 |
//+------------------------------------------------------------------+
input group "=== Spread Filter ==="
input bool    UseSpreadFilter           = true;           // Enable Spread Filter
input double  MaxSpreadPips             = 2.0;            // Max Spread (pips) to Enter

//+------------------------------------------------------------------+
//| Input Parameters - Session Filter                                |
//+------------------------------------------------------------------+
input group "=== Session Filter ==="
input bool    UseSessionFilter          = true;           // Enable Session Filter
input int     Session1_StartHour        = 6;              // Session 1 Start (server hour)
input int     Session1_EndHour          = 12;             // Session 1 End (London + overlap)
input int     Session2_StartHour        = 13;             // Session 2 Start (server hour)
input int     Session2_EndHour          = 18;             // Session 2 End (NY full AM)
input bool    AvoidFirstMinutes         = false;          // Skip First 5 Min of Each Hour

//+------------------------------------------------------------------+
//| Input Parameters - General                                       |
//+------------------------------------------------------------------+
input group "=== General ==="
input int     MagicNumber               = 20250606;       // Magic Number
input string  TradeComment              = "FXScalp2";     // Trade Comment
input int     Slippage                  = 10;             // Max Slippage (points)
input bool    PrintLogs                 = true;           // Print Diagnostic Logs

//+------------------------------------------------------------------+
//| Indicator Handles                                                |
//+------------------------------------------------------------------+
int h_emaFast;       // Fast EMA on chart TF
int h_emaSlow;       // Slow EMA on chart TF
int h_emaTrend;      // Trend EMA on chart TF (50)
int h_rsi;           // RSI on chart TF
int h_macd;          // MACD on chart TF
int h_atrH1;         // ATR on H1 (stable stop sizing)
int h_htfEmaFast;    // Fast EMA on HTF
int h_htfEmaSlow;    // Slow EMA on HTF

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
double pipMultiplier;
double pipSize;

// Daily counters
int    g_dailyTrades;
int    g_dailyLosses;
datetime g_lastTradeDate;

// Partial close tracking: store ticket of position that already had partial close
// Uses a simple array of tickets (max 10 tracked at a time)
ulong  g_partialClosedTickets[10];
int    g_partialClosedCount;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(EMA_Fast_Period >= EMA_Slow_Period)
   {
      Print("ERROR: Fast EMA (", EMA_Fast_Period, ") must be < Slow EMA (", EMA_Slow_Period, ")");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(MinSignalStrength < 1 || MinSignalStrength > 7)
   {
      Print("ERROR: MinSignalStrength must be 1-5");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(RR_Ratio < 1.0)
   {
      Print("ERROR: R:R Ratio must be >= 1.0");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Pip sizing
   if(_Digits == 5 || _Digits == 3)
      pipMultiplier = 10.0;
   else
      pipMultiplier = 1.0;
   pipSize = pipMultiplier * _Point;

   //--- Create indicator handles
   h_emaFast    = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_emaSlow    = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_emaTrend   = iMA(_Symbol, PERIOD_CURRENT, EMA_Trend_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi        = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   h_macd       = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   h_atrH1      = iATR(_Symbol, PERIOD_H1, ATR_Period);  // H1 ATR for stable stops
   h_htfEmaFast = iMA(_Symbol, HTF_Timeframe, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_htfEmaSlow = iMA(_Symbol, HTF_Timeframe, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(h_emaFast == INVALID_HANDLE || h_emaSlow == INVALID_HANDLE ||
      h_emaTrend == INVALID_HANDLE || h_rsi == INVALID_HANDLE ||
      h_macd == INVALID_HANDLE || h_atrH1 == INVALID_HANDLE ||
      h_htfEmaFast == INVALID_HANDLE || h_htfEmaSlow == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }

   //--- Trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- State
   g_dailyTrades = 0;
   g_dailyLosses = 0;
   g_lastTradeDate = 0;
   g_partialClosedCount = 0;
   ArrayInitialize(g_partialClosedTickets, 0);

   //--- Log
   if(PrintLogs)
   {
      Print("============================================");
      Print("ForexScalper EA V2.00 Initialized");
      Print("Symbol: ", _Symbol, " | TF: ", EnumToString(Period()));
      Print("Mode: ", EnumToString(SignalMode), " | Min Strength: ", MinSignalStrength, "/5");
      Print("EMA: ", EMA_Fast_Period, "/", EMA_Slow_Period, "/", EMA_Trend_Period);
      Print("RSI: ", RSI_Period, " | MACD: ", MACD_Fast, "/", MACD_Slow, "/", MACD_Signal);
      Print("SL: ", SL_Mode == SL_ATR_BASED ? "H1 ATR-Based" : "Fixed",
            " (", DoubleToString(ATR_SL_Multiplier, 2), "x) | R:R=1:", DoubleToString(RR_Ratio, 1));
      Print("SL Range: ", DoubleToString(MinSL_Pips, 1), "-", DoubleToString(MaxSL_Pips, 1), " pips");
      Print("Partial Close: ", UsePartialClose ? "50% at 1R" : "OFF",
            " | Trail: ", UseTrailingStop ? "ON" : "OFF");
      Print("Spread Filter: ", UseSpreadFilter ? DoubleToString(MaxSpreadPips, 1) + " pips max" : "OFF");
      Print("HTF Filter: ", FilterByHTFTrend ? EnumToString(HTF_Timeframe) : "OFF");
      Print("Risk: ", DoubleToString(RiskPercent, 1), "%",
            " | Max/Day: ", MaxDailyTrades, " | Max Losses/Day: ", MaxDailyLosses);
      Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
      Print("============================================");
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(h_emaFast    != INVALID_HANDLE) IndicatorRelease(h_emaFast);
   if(h_emaSlow    != INVALID_HANDLE) IndicatorRelease(h_emaSlow);
   if(h_emaTrend   != INVALID_HANDLE) IndicatorRelease(h_emaTrend);
   if(h_rsi        != INVALID_HANDLE) IndicatorRelease(h_rsi);
   if(h_macd       != INVALID_HANDLE) IndicatorRelease(h_macd);
   if(h_atrH1      != INVALID_HANDLE) IndicatorRelease(h_atrH1);
   if(h_htfEmaFast != INVALID_HANDLE) IndicatorRelease(h_htfEmaFast);
   if(h_htfEmaSlow != INVALID_HANDLE) IndicatorRelease(h_htfEmaSlow);
   Print("ForexScalper EA V2 stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Daily reset
   ResetDailyCounters();

   //--- Manage open positions every tick (partial close, breakeven, trail)
   ManageOpenPositions();

   //--- New signals only on new bar
   if(!IsNewBar())
      return;

   //--- Daily limits
   if(MaxDailyTrades > 0 && g_dailyTrades >= MaxDailyTrades)
      return;
   if(MaxDailyLosses > 0 && g_dailyLosses >= MaxDailyLosses)
      return;

   //--- Position limit
   if(CountPositions() >= MaxActiveTrades)
      return;

   //--- Session filter
   if(UseSessionFilter && !IsWithinTradingSession())
      return;

   //--- Spread filter
   if(UseSpreadFilter)
   {
      double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pipSize;
      if(spread > MaxSpreadPips)
         return;
   }

   //--- Read indicators
   double emaFastBuf[4], emaSlowBuf[4], emaTrendBuf[2], rsiBuf[2];
   double macdMainBuf[3], macdSigBuf[3], htfFastBuf[2], htfSlowBuf[2];
   double atrH1Buf[2];

   if(CopyBuffer(h_emaFast, 0, 1, 4, emaFastBuf) < 4) return;
   if(CopyBuffer(h_emaSlow, 0, 1, 4, emaSlowBuf) < 4) return;
   if(CopyBuffer(h_emaTrend, 0, 1, 2, emaTrendBuf) < 2) return;
   if(CopyBuffer(h_rsi, 0, 1, 2, rsiBuf) < 2) return;
   if(CopyBuffer(h_macd, 0, 1, 3, macdMainBuf) < 3) return;
   if(CopyBuffer(h_macd, 1, 1, 3, macdSigBuf) < 3) return;
   if(CopyBuffer(h_atrH1, 0, 0, 2, atrH1Buf) < 2) return;
   if(CopyBuffer(h_htfEmaFast, 0, 0, 2, htfFastBuf) < 2) return;
   if(CopyBuffer(h_htfEmaSlow, 0, 0, 2, htfSlowBuf) < 2) return;

   // Array index: [0]=bar1, [1]=bar2, [2]=bar3, [3]=bar4
   double curEmaFast   = emaFastBuf[0];
   double curEmaSlow   = emaSlowBuf[0];
   double prevEmaFast  = emaFastBuf[1];
   double prevEmaSlow  = emaSlowBuf[1];
   double prev2EmaFast = emaFastBuf[2];
   double prev2EmaSlow = emaSlowBuf[2];
   double curEmaTrend  = emaTrendBuf[0];
   double curRSI       = rsiBuf[0];
   double curATR_H1    = atrH1Buf[0];

   double curMacdMain  = macdMainBuf[0];
   double curMacdSig   = macdSigBuf[0];
   double prevMacdMain = macdMainBuf[1];
   double prevMacdSig  = macdSigBuf[1];
   double curMacdHist  = curMacdMain - curMacdSig;

   bool htfBullish = htfFastBuf[0] > htfSlowBuf[0];
   bool htfBearish = htfFastBuf[0] < htfSlowBuf[0];

   //--- Price data (bar 1 = last closed)
   double open1  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double high1  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low1   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double range1 = high1 - low1;

   //--- EMA state
   bool emaBullish = curEmaFast > curEmaSlow;
   bool emaBearish = curEmaFast < curEmaSlow;

   // EMA cross happened in recent 5 bars (allows proper pullback entry after cross)
   bool recentBullCross = false;
   bool recentBearCross = false;
   for(int k = 0; k < 3; k++) // check pairs: [0,1], [1,2], [2,3]
   {
      if(emaFastBuf[k] > emaSlowBuf[k] && emaFastBuf[k+1] <= emaSlowBuf[k+1])
         recentBullCross = true;
      if(emaFastBuf[k] < emaSlowBuf[k] && emaFastBuf[k+1] >= emaSlowBuf[k+1])
         recentBearCross = true;
   }

   //--- EMA slope: fast EMA must be moving in trade direction
   double emaSlopeUp   = (curEmaFast - emaFastBuf[2]) / pipSize;  // pips over 2 bars
   double emaSlopeDown = (emaFastBuf[2] - curEmaFast) / pipSize;

   //--- Trend structure: price above/below EMA 50
   bool aboveTrendEMA = close1 > curEmaTrend;
   bool belowTrendEMA = close1 < curEmaTrend;

   //--- Pullback detection: price touched or came near fast EMA
   // Dynamic pullback zone: use fraction of H1 ATR (adapts to volatility)
   double pullbackZone = curATR_H1 * 0.5;  // half of H1 ATR = generous zone
   // For longs: low wicked into fast EMA zone
   bool longPullback = emaBullish && (low1 <= curEmaFast + pullbackZone) && (close1 > curEmaFast);
   // For shorts: high wicked into fast EMA zone
   bool shortPullback = emaBearish && (high1 >= curEmaFast - pullbackZone) && (close1 < curEmaFast);
   // Near slow EMA also counts as a deep pullback (price near EMA 21)
   bool longDeepPB  = emaBullish && (low1 <= curEmaSlow + pullbackZone) && (close1 > curEmaSlow);
   bool shortDeepPB = emaBearish && (high1 >= curEmaSlow - pullbackZone) && (close1 < curEmaSlow);

   //--- MACD
   bool macdBullish  = curMacdHist > 0;
   bool macdBearish  = curMacdHist < 0;
   bool macdCrossUp  = (prevMacdMain <= prevMacdSig) && (curMacdMain > curMacdSig);
   bool macdCrossDown= (prevMacdMain >= prevMacdSig) && (curMacdMain < curMacdSig);

   //--- Volume
   long tickVolBuf[];
   if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 1, 21, tickVolBuf) < 21) return;
   double avgVol = 0;
   for(int i = 1; i < 21; i++)
      avgVol += (double)tickVolBuf[i];
   avgVol /= 20.0;
   bool highVolume = ((double)tickVolBuf[0] > avgVol * VolumeMultiplier);

   //--- Candle quality: strong body (>50% range) and basic bullish/bearish close (>30%)
   bool strongBullCandle = (close1 > open1) && (range1 > 0) && ((close1 - open1) > range1 * 0.5);
   bool strongBearCandle = (close1 < open1) && (range1 > 0) && ((open1 - close1) > range1 * 0.5);
   bool bullishCandle = (close1 > open1) && (range1 > 0) && ((close1 - open1) > range1 * 0.3);
   bool bearishCandle = (close1 < open1) && (range1 > 0) && ((open1 - close1) > range1 * 0.3);

   //--- RSI thresholds
   double rsiOversold, rsiOverbought;
   GetRSIThresholds(rsiOversold, rsiOverbought);

   //=================================================================
   // LONG SIGNAL — Trigger (required) + Strength Score (quality gate)
   // Only 2 hard requirements: EMA bullish + trigger candle
   // Everything else is scored — minimum score decides trade quality
   //=================================================================
   bool longTrigger = false;

   // Trigger A: Pullback to fast EMA + bullish close
   if(longPullback && bullishCandle)
      longTrigger = true;

   // Trigger B: Deep pullback to slow EMA + bullish close
   if(longDeepPB && bullishCandle)
      longTrigger = true;

   // Trigger C: Recent EMA cross up + bullish candle
   if(recentBullCross && bullishCandle)
      longTrigger = true;

   // Trigger D: Strong bullish candle in EMA bullish trend
   if(emaBullish && strongBullCandle)
      longTrigger = true;

   // Only hard filter: EMA 9 > EMA 21
   bool longSignal = longTrigger && emaBullish;

   //=================================================================
   // SHORT SIGNAL
   //=================================================================
   bool shortTrigger = false;

   if(shortPullback && bearishCandle)
      shortTrigger = true;

   if(shortDeepPB && bearishCandle)
      shortTrigger = true;

   if(recentBearCross && bearishCandle)
      shortTrigger = true;

   if(emaBearish && strongBearCandle)
      shortTrigger = true;

   bool shortSignal = shortTrigger && emaBearish;

   //=================================================================
   // SIGNAL STRENGTH — Scoring system (soft filters, not hard gates)
   // Each confluence adds 1 point. MinSignalStrength filters weak setups.
   //=================================================================
   int longStr = 0;
   if(emaBullish)      longStr++;   // 1. EMA 9/21 bullish
   if(aboveTrendEMA)   longStr++;   // 2. Price above EMA 50
   if(htfBullish)      longStr++;   // 3. HTF trend aligned
   if(macdBullish || macdCrossUp)  longStr++;  // 4. MACD confirms
   if(highVolume)      longStr++;   // 5. Above-average volume
   if(curRSI > rsiOversold && curRSI < 70) longStr++;  // 6. RSI not extreme
   if(emaSlopeUp > 0.1) longStr++;  // 7. EMA rising

   int shortStr = 0;
   if(emaBearish)      shortStr++;
   if(belowTrendEMA)   shortStr++;
   if(htfBearish)      shortStr++;
   if(macdBearish || macdCrossDown) shortStr++;
   if(highVolume)      shortStr++;
   if(curRSI < rsiOverbought && curRSI > 30) shortStr++;
   if(emaSlopeDown > 0.1) shortStr++;

   // Quality gate: require minimum score (default 2 of 7)
   if(longSignal && longStr < MinSignalStrength)
      longSignal = false;
   if(shortSignal && shortStr < MinSignalStrength)
      shortSignal = false;

   //--- Debounce
   static int lastLongBar  = 0;
   static int lastShortBar = 0;
   int currentBar = iBars(_Symbol, PERIOD_CURRENT);
   int minBars = GetMinBarsBetween();

   if(longSignal && (currentBar - lastLongBar) <= minBars)
      longSignal = false;
   if(shortSignal && (currentBar - lastShortBar) <= minBars)
      shortSignal = false;

   //--- Execute
   if(longSignal)
   {
      double slPips = GetStopLossPips(curATR_H1);
      double tpPips = slPips * RR_Ratio;

      if(OpenPosition(true, slPips, tpPips))
      {
         lastLongBar = currentBar;
         g_dailyTrades++;
         if(PrintLogs)
            Print("LONG [", longStr, "/7] | RSI=", DoubleToString(curRSI, 1),
                  " | MACD=", DoubleToString(curMacdHist, 6),
                  " | ATR(H1)=", DoubleToString(curATR_H1 / pipSize, 1), "p",
                  " | SL=", DoubleToString(slPips, 1), "p | TP=", DoubleToString(tpPips, 1), "p",
                  " | Vol=", highVolume ? "H" : "N",
                  " | Pullback=", longPullback ? "Y" : "N",
                  " | Cross=", recentBullCross ? "Y" : "N");
      }
   }

   if(shortSignal)
   {
      double slPips = GetStopLossPips(curATR_H1);
      double tpPips = slPips * RR_Ratio;

      if(OpenPosition(false, slPips, tpPips))
      {
         lastShortBar = currentBar;
         g_dailyTrades++;
         if(PrintLogs)
            Print("SHORT [", shortStr, "/7] | RSI=", DoubleToString(curRSI, 1),
                  " | MACD=", DoubleToString(curMacdHist, 6),
                  " | ATR(H1)=", DoubleToString(curATR_H1 / pipSize, 1), "p",
                  " | SL=", DoubleToString(slPips, 1), "p | TP=", DoubleToString(tpPips, 1), "p",
                  " | Vol=", highVolume ? "H" : "N",
                  " | Pullback=", shortPullback ? "Y" : "N",
                  " | Cross=", recentBearCross ? "Y" : "N");
      }
   }
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBarTime != lastBarTime)
   {
      lastBarTime = curBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Reset daily counters                                             |
//+------------------------------------------------------------------+
void ResetDailyCounters()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != g_lastTradeDate)
   {
      g_dailyTrades = 0;
      g_dailyLosses = 0;
      g_lastTradeDate = today;
   }
}

//+------------------------------------------------------------------+
//| Session filter                                                   |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   int min  = dt.min;

   // Skip first 5 minutes of each hour (spread can be wide)
   if(AvoidFirstMinutes && min < 5)
      return false;

   // Session 1 (London AM)
   if(hour >= Session1_StartHour && hour < Session1_EndHour)
      return true;

   // Session 2 (NY AM)
   if(hour >= Session2_StartHour && hour < Session2_EndHour)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| RSI thresholds by mode                                           |
//+------------------------------------------------------------------+
void GetRSIThresholds(double &oversold, double &overbought)
{
   switch(SignalMode)
   {
      case MODE_AGGRESSIVE:   oversold = 40; overbought = 60; break;
      case MODE_BALANCED:     oversold = 35; overbought = 65; break;
      case MODE_CONSERVATIVE: oversold = 30; overbought = 70; break;
      default:                oversold = 35; overbought = 65;
   }
}

//+------------------------------------------------------------------+
//| Debounce bars by mode                                            |
//+------------------------------------------------------------------+
int GetMinBarsBetween()
{
   switch(SignalMode)
   {
      case MODE_AGGRESSIVE:   return 3;
      case MODE_BALANCED:     return 4;
      case MODE_CONSERVATIVE: return 6;
      default:                return 4;
   }
}

//+------------------------------------------------------------------+
//| (Signal strength is now calculated inline in OnTick)             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Get stop loss in pips using H1 ATR                               |
//+------------------------------------------------------------------+
double GetStopLossPips(double atrH1Value)
{
   if(SL_Mode == SL_FIXED)
      return MathMax(FixedSL_Pips, MinSL_Pips);

   double slPips = (atrH1Value * ATR_SL_Multiplier) / pipSize;
   slPips = MathMax(slPips, MinSL_Pips);
   slPips = MathMin(slPips, MaxSL_Pips);
   return slPips;
}

//+------------------------------------------------------------------+
//| Position size from risk                                          |
//+------------------------------------------------------------------+
double CalculatePositionSize(double slPips)
{
   if(RiskPercent <= 0)
      return ValidateLotSize(FixedLotSize);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * RiskPercent / 100.0;
   double slPrice = slPips * pipSize;

   double tvl = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tsz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tvl <= 0 || tsz <= 0 || slPrice <= 0)
      return ValidateLotSize(FixedLotSize);

   double slTicks = slPrice / tsz;
   double lots = riskAmt / (slTicks * tvl);
   return ValidateLotSize(lots);
}

//+------------------------------------------------------------------+
//| Open BUY or SELL position                                        |
//+------------------------------------------------------------------+
bool OpenPosition(bool isBuy, double slPips, double tpPips)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * point;

   double price, slPrice, tpPrice;

   if(isBuy)
   {
      price   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      slPrice = NormalizeDouble(price - slPips * pipSize, digits);
      tpPrice = NormalizeDouble(price + tpPips * pipSize, digits);

      if(stopsLevel > 0)
      {
         if((price - slPrice) < minDist)
            slPrice = NormalizeDouble(price - minDist - point, digits);
         if((tpPrice - price) < minDist)
            tpPrice = NormalizeDouble(price + minDist + point, digits);
      }
   }
   else
   {
      price   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      slPrice = NormalizeDouble(price + slPips * pipSize, digits);
      tpPrice = NormalizeDouble(price - tpPips * pipSize, digits);

      if(stopsLevel > 0)
      {
         if((slPrice - price) < minDist)
            slPrice = NormalizeDouble(price + minDist + point, digits);
         if((price - tpPrice) < minDist)
            tpPrice = NormalizeDouble(price - minDist - point, digits);
      }
   }

   if(price <= 0) return false;

   double lots = CalculatePositionSize(slPips);
   if(lots <= 0) return false;

   string dir = isBuy ? "L" : "S";
   string comment = StringFormat("%s_%s_%.0f/%.0f", TradeComment, dir, slPips, tpPips);

   bool ok;
   if(isBuy)
      ok = trade.Buy(lots, _Symbol, price, slPrice, tpPrice, comment);
   else
      ok = trade.Sell(lots, _Symbol, price, slPrice, tpPrice, comment);

   if(ok)
   {
      if(PrintLogs)
         Print(isBuy ? "BUY" : "SELL", " OPENED: Price=", DoubleToString(price, digits),
               " SL=", DoubleToString(slPrice, digits), "(", DoubleToString(slPips, 1), "p)",
               " TP=", DoubleToString(tpPrice, digits), "(", DoubleToString(tpPips, 1), "p)",
               " Lots=", DoubleToString(lots, 2));
      return true;
   }

   Print(isBuy ? "BUY" : "SELL", " FAILED: ", trade.ResultRetcode(),
         " - ", trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| Manage open positions: partial close at 1R, BE, trailing         |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Get H1 ATR for trailing
   double atrBuf[1];
   double curATR = 0;
   if(UseTrailingStop && CopyBuffer(h_atrH1, 0, 0, 1, atrBuf) >= 1)
      curATR = atrBuf[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == "" || posSymbol == NULL) continue;
      if(posSymbol != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double posLots   = PositionGetDouble(POSITION_VOLUME);
      ulong  ticket    = PositionGetInteger(POSITION_TICKET);
      int    posType   = (int)PositionGetInteger(POSITION_TYPE);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double initialRisk = 0;
      double currentProfit = 0;

      if(posType == POSITION_TYPE_BUY)
      {
         initialRisk = openPrice - currentSL;
         currentProfit = bid - openPrice;
      }
      else
      {
         initialRisk = currentSL - openPrice;
         currentProfit = openPrice - ask;
      }

      if(initialRisk <= 0) continue;

      bool reached1R = (currentProfit >= initialRisk);

      //--- Partial close at 1R (close ~50% of position)
      if(UsePartialClose && reached1R && !IsPartialClosed(ticket))
      {
         double closeLots = PartialLotSize(posLots);
         if(closeLots > 0)
         {
            if(posType == POSITION_TYPE_BUY)
               trade.Sell(closeLots, _Symbol, bid, 0, 0, "Partial_1R");
            else
               trade.Buy(closeLots, _Symbol, ask, 0, 0, "Partial_1R");

            MarkPartialClosed(ticket);

            if(PrintLogs)
               Print("PARTIAL CLOSE at 1R: Ticket=", ticket,
                     " | Closed=", DoubleToString(closeLots, 2),
                     " | Remaining=", DoubleToString(posLots - closeLots, 2));
         }
      }

      //--- Breakeven: after 1R (or after partial close), move SL to entry + buffer
      if(UseBreakeven && reached1R)
      {
         double newSL = currentSL;

         if(posType == POSITION_TYPE_BUY)
         {
            double beSL = NormalizeDouble(openPrice + BreakevenBufferPips * pipSize, digits);
            if(beSL > currentSL)
               newSL = beSL;
         }
         else
         {
            double beSL = NormalizeDouble(openPrice - BreakevenBufferPips * pipSize, digits);
            if(beSL < currentSL)
               newSL = beSL;
         }

         if(newSL != currentSL)
            trade.PositionModify(ticket, NormalizeDouble(newSL, digits), currentTP);
      }

      //--- Trailing stop: only after 1R, trail H1 ATR behind price
      if(UseTrailingStop && reached1R && curATR > 0)
      {
         double trailDist = curATR * TrailingATR_Mult;

         if(posType == POSITION_TYPE_BUY)
         {
            double trailSL = NormalizeDouble(bid - trailDist, digits);
            if(trailSL > currentSL && trailSL > openPrice)
               trade.PositionModify(ticket, trailSL, currentTP);
         }
         else
         {
            double trailSL = NormalizeDouble(ask + trailDist, digits);
            if(trailSL < currentSL && trailSL < openPrice)
               trade.PositionModify(ticket, trailSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if ticket already had partial close                        |
//+------------------------------------------------------------------+
bool IsPartialClosed(ulong ticket)
{
   for(int i = 0; i < g_partialClosedCount; i++)
   {
      if(g_partialClosedTickets[i] == ticket)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Mark ticket as partially closed                                  |
//+------------------------------------------------------------------+
void MarkPartialClosed(ulong ticket)
{
   if(g_partialClosedCount >= 10)
   {
      // Shift array: remove oldest
      for(int i = 0; i < 9; i++)
         g_partialClosedTickets[i] = g_partialClosedTickets[i + 1];
      g_partialClosedCount = 9;
   }
   g_partialClosedTickets[g_partialClosedCount] = ticket;
   g_partialClosedCount++;
}

//+------------------------------------------------------------------+
//| Calculate lots for partial close (~50%)                          |
//+------------------------------------------------------------------+
double PartialLotSize(double totalLots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0 || lotStep <= 0)
      return 0;

   double halfLots = MathFloor((totalLots * 0.5) / lotStep) * lotStep;

   // Must leave at least minLot remaining
   if((totalLots - halfLots) < minLot)
      return 0; // Can't partial close, position too small

   if(halfLots < minLot)
      return 0;

   return NormalizeDouble(halfLots, 2);
}

//+------------------------------------------------------------------+
//| Count open positions                                             |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == "" || posSymbol == NULL) continue;
      if(posSymbol != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Track closed trades for daily loss counter                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(magic != MagicNumber) return;

         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
         {
            double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
            double netPnL = profit + commission + swap;

            if(netPnL < 0)
               g_dailyLosses++;

            if(PrintLogs)
               Print("CLOSED: PnL=$", DoubleToString(netPnL, 2),
                     " | Daily: ", g_dailyTrades, "/", MaxDailyTrades,
                     " | Losses: ", g_dailyLosses, "/", MaxDailyLosses);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Validate lot size                                                |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0)
   {
      Print("ERROR: Invalid volume info");
      return -1.0;
   }

   double lots = MathFloor(requestedLots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+

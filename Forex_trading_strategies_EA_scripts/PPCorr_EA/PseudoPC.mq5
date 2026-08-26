//+------------------------------------------------------------------+
//| PseudoPC.mq5                                                      |
//| Pseudo Pearson Correlation Indicator                               |
//| Correlates DeMarker vs MFI, using RSI as the reference baseline  |
//+------------------------------------------------------------------+
#property strict
#property copyright "Pseudo Pearson Correlation"
#property version   "1.00"
#property description "Pseudo Pearson Correlation of DeMarker and MFI with RSI baseline"

//--- Indicator displayed in a separate subwindow
#property indicator_separate_window

//--- One output buffer plotted as a line
#property indicator_buffers 1
#property indicator_plots   1

//--- Plot settings
#property indicator_label1  "PseudoPC"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Horizontal reference levels
#property indicator_level1  -0.80
#property indicator_level2  -0.50
#property indicator_level3   0.00
#property indicator_level4   0.50
#property indicator_level5   0.80
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT

//--- Y-axis range
#property indicator_minimum -1.0
#property indicator_maximum  1.0

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input int CorrPeriod = 21;    // Correlation Lookback Period
input int RSIPeriod  = 14;    // RSI Period
input int MFIPeriod  = 14;    // MFI Period
input int DeMPeriod  = 14;    // DeMarker Period

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+

// Output buffer
double PPCBuffer[];

// Indicator handles
int rsiHandle;
int mfiHandle;
int demHandle;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Input validation
   if(CorrPeriod <= 1)
   {
      Print("ERROR: CorrPeriod must be > 1. Got: ", CorrPeriod);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(RSIPeriod <= 0 || MFIPeriod <= 0 || DeMPeriod <= 0)
   {
      Print("ERROR: All periods must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Set up indicator buffer
   SetIndexBuffer(0, PPCBuffer, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, CorrPeriod + MathMax(RSIPeriod, MathMax(MFIPeriod, DeMPeriod)));

   //--- Create indicator handles
   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create RSI handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   // MFI uses tick volume
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

   //--- Set short name displayed in the indicator subwindow
   string shortName = StringFormat("PPr[ Corr=%d RSI=%d MFI=%d DeM=%d ]",
                                    CorrPeriod, RSIPeriod, MFIPeriod, DeMPeriod);
   IndicatorSetString(INDICATOR_SHORTNAME, shortName);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(mfiHandle != INVALID_HANDLE) IndicatorRelease(mfiHandle);
   if(demHandle != INVALID_HANDLE) IndicatorRelease(demHandle);
}

//+------------------------------------------------------------------+
//| Custom indicator calculation function                            |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   //--- Minimum bars needed: indicator warmup + correlation period
   int minBars = CorrPeriod + MathMax(RSIPeriod, MathMax(MFIPeriod, DeMPeriod));
   if(rates_total < minBars)
      return 0;

   //--- Copy indicator data for all bars we need
   // We need enough data to cover the full correlation lookback window
   double rsiData[];
   double mfiData[];
   double demData[];

   if(CopyBuffer(rsiHandle, 0, 0, rates_total, rsiData) <= 0) return 0;
   if(CopyBuffer(mfiHandle, 0, 0, rates_total, mfiData) <= 0) return 0;
   if(CopyBuffer(demHandle, 0, 0, rates_total, demData) <= 0) return 0;

   //--- Determine starting bar for calculation
   int start = prev_calculated;
   if(start < minBars)
      start = minBars;

   //--- Calculate Pseudo Pearson Correlation for each bar
   for(int i = start; i < rates_total; i++)
   {
      double sum_xy = 0.0;
      double sum_x2 = 0.0;
      double sum_y2 = 0.0;

      //--- Loop back CorrPeriod bars to compute correlation
      for(int j = 0; j < CorrPeriod; j++)
      {
         int idx = i - j;
         if(idx < 0) break;

         // x = DeMarker value (already 0-1)
         double x = demData[idx];

         // y = MFI value / 100 (normalize to 0-1)
         double y = mfiData[idx] / 100.0;

         // z = RSI value / 100 (normalize to 0-1, used as reference baseline)
         double z = rsiData[idx] / 100.0;

         // Compute deviations from RSI baseline
         double dx = x - z;  // DeMarker deviation from RSI
         double dy = y - z;  // MFI deviation from RSI

         // Accumulate for Pearson formula
         sum_xy += dx * dy;
         sum_x2 += dx * dx;
         sum_y2 += dy * dy;
      }

      //--- Compute Pseudo Pearson Correlation: r' = sum_xy / sqrt(sum_x2 * sum_y2)
      double denominator = MathSqrt(sum_x2 * sum_y2);

      if(denominator <= 0.0)
      {
         // Zero denominator means no variance — assign empty value
         PPCBuffer[i] = EMPTY_VALUE;
      }
      else
      {
         double r = sum_xy / denominator;
         // Clamp to [-1, +1] for safety
         r = MathMax(-1.0, MathMin(1.0, r));
         PPCBuffer[i] = r;
      }
   }

   return rates_total;
}
//+------------------------------------------------------------------+

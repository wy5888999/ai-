//+------------------------------------------------------------------+
//|                                                 XAU_ShortMA.mq5  |
//| 5分钟 EMA5 / EMA10 / EMA20，画在当前图表上。不嵌套 iMA。          |
//+------------------------------------------------------------------+
#property copyright "xauusd-quant"
#property version   "1.04"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3
#property indicator_label1  "EMA5"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_width1  2
#property indicator_label2  "EMA10"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDeepSkyBlue
#property indicator_width2  2
#property indicator_label3  "EMA20"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrTomato
#property indicator_width3  2

double g5[];
double g10[];
double g20[];

void BuildEma(const double &price[], const int n, const int period, double &out[])
  {
   ArrayResize(out, n);
   if(n <= 0)
      return;
   double k = 2.0 / (period + 1.0);
   double ema = price[0];
   out[0] = ema;
   for(int i = 1; i < n; i++)
     {
      ema = price[i] * k + ema * (1.0 - k);
      out[i] = ema;
     }
  }

int OnInit()
  {
   SetIndexBuffer(0, g5, INDICATOR_DATA);
   SetIndexBuffer(1, g10, INDICATOR_DATA);
   SetIndexBuffer(2, g20, INDICATOR_DATA);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   IndicatorSetString(INDICATOR_SHORTNAME, "M5短线均线");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return INIT_SUCCEEDED;
  }

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
   if(rates_total < 2)
      return 0;
   int sec = PeriodSeconds(_Period);
   if(sec <= 0)
      sec = 60;
   int perBar = (sec <= 60 ? 1 : sec / 60);
   int need = rates_total * perBar + 40;
   if(need < 80)
      need = 80;
   double mc[];
   datetime mt[];
   ArraySetAsSeries(mc, false);
   ArraySetAsSeries(mt, false);
   int n = CopyClose(_Symbol, PERIOD_M5, 0, need, mc);
   int nt = CopyTime(_Symbol, PERIOD_M5, 0, need, mt);
   if(n < 30 || nt < 30)
      return 0;
   if(nt < n)
      n = nt;
   double e5[], e10[], e20[];
   BuildEma(mc, n, 5, e5);
   BuildEma(mc, n, 10, e10);
   BuildEma(mc, n, 20, e20);
   int start = (prev_calculated > 1 ? prev_calculated - 1 : 0);
   int j = 0;
   for(int i = start; i < rates_total; i++)
     {
      datetime barEnd = time[i] + (datetime)sec - 1;
      if(i == rates_total - 1 || barEnd > TimeCurrent())
         barEnd = TimeCurrent();
      while(j + 1 < n && mt[j + 1] <= barEnd)
         j++;
      if(mt[j] <= barEnd)
        {
         g5[i] = e5[j];
         g10[i] = e10[j];
         g20[i] = e20[j];
        }
     }
   return rates_total;
  }

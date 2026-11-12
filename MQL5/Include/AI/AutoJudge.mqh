//+------------------------------------------------------------------+
//| AutoJudge.mqh                                                    |
//| 自动研判：ADX/EMA/RSI/ATR + 短线反弹过滤（防假偏空/假偏多）       |
//| 外部信号：DIR,CONF,FREEZE[,reason]  （Common\Files\ai\signal.txt）|
//| 教学文件：ai\teach.txt（WHY_TREND / WHY_SUP / SUP1.. 仅辅助）     |
//+------------------------------------------------------------------+
#ifndef AUTO_JUDGE_MQH
#define AUTO_JUDGE_MQH

string g_line_judge = "判断 等待";
int    g_ai_ma_dir   = 0;          // 1=做多 -1=做空 0=先别做。只在回踩后才置位，不在极值追

enum ENUM_MARKET_REGIME
  {
   REGIME_RANGE = 0,
   REGIME_TREND = 1
  };

enum ENUM_TREND_DIR
  {
   TREND_FLAT      = 0,
   TREND_UP        = 1,
   TREND_DOWN      = 2,
   TREND_LEAN_UP   = 3,
   TREND_LEAN_DOWN = 4
  };

#define AI_OBJ_SUP1 "XAU_AI_SUP1"
#define AI_OBJ_SUP2 "XAU_AI_SUP2"
#define AI_OBJ_RES1 "XAU_AI_RES1"
struct JudgeResult
  {
   ENUM_MARKET_REGIME regime;
   ENUM_TREND_DIR     direction;
   double             confidence;
   string             reason;
   bool               from_external_ai;
   bool               freeze_orders;   // 教学提示：1=建议先别加（EA 可不强制）
   double             support1;
   double             support2;
   double             resist1;
   double             step_hint;
   string             why_trend;
   string             why_sup;
   string             lesson;
   string             signal_bar;      // 这根方向对应的正在走的 M5（yyyy.mm.dd hh:mi）
  };

void AutoJudge_Clear(JudgeResult &out)
  {
   out.regime = REGIME_RANGE;
   out.direction = TREND_FLAT;
   out.confidence = 50.0;
   out.reason = "";
   out.from_external_ai = false;
   out.freeze_orders = false;
   out.support1 = 0.0;
   out.support2 = 0.0;
   out.resist1 = 0.0;
   out.step_hint = 0.0;
   out.why_trend = "";
   out.why_sup = "";
   out.lesson = "";
   out.signal_bar = "";
  }

bool AutoJudge_ParseDirectionToken(string d, ENUM_TREND_DIR &dir)
  {
   StringToUpper(d);
   if(d == "UP" || d == "BUY" || d == "LONG" || d == "TREND_UP")
     {
      dir = TREND_UP;
      return true;
     }
   if(d == "DOWN" || d == "SELL" || d == "SHORT" || d == "TREND_DOWN")
     {
      dir = TREND_DOWN;
      return true;
     }
   if(d == "LEAN_UP" || d == "NEUTRAL_UP" || d == "偏多")
     {
      dir = TREND_LEAN_UP;
      return true;
     }
   if(d == "LEAN_DOWN" || d == "NEUTRAL_DOWN" || d == "偏空")
     {
      dir = TREND_LEAN_DOWN;
      return true;
     }
   if(d == "FLAT" || d == "NEUTRAL" || d == "中性")
     {
      dir = TREND_FLAT;
      return true;
     }
   return false;
  }

void AutoJudge_SetRegimeFromDir(JudgeResult &out)
  {
   if(out.direction == TREND_UP || out.direction == TREND_DOWN)
      out.regime = REGIME_TREND;
   else
      out.regime = REGIME_RANGE;
  }

// 新格式: DIR,CONF,FREEZE[,reason]
// 旧格式: REGIME,DIR,CONF[,reason] 或 REGIME,DIR,CONF,reason,FREEZE
bool AutoJudge_ParseExternal(const string line, JudgeResult &out)
  {
   AutoJudge_Clear(out);
   string parts[];
   int n = StringSplit(line, ',', parts);
   if(n < 3)
      return false;

   string p0 = parts[0];
   StringTrimLeft(p0);
   StringTrimRight(p0);
   StringToUpper(p0);

   // ---- 旧格式 REGIME,DIR,CONF ----
   if(p0 == "TREND" || p0 == "RANGE")
     {
      out.regime = (p0 == "TREND" ? REGIME_TREND : REGIME_RANGE);
      string d = parts[1];
      StringTrimLeft(d);
      StringTrimRight(d);
      if(!AutoJudge_ParseDirectionToken(d, out.direction))
         out.direction = TREND_FLAT;

      out.confidence = StringToDouble(parts[2]);
      if(out.confidence < 0.0) out.confidence = 0.0;
      if(out.confidence > 100.0) out.confidence = 100.0;

      out.freeze_orders = false;
      if(n >= 5)
        {
         string fr = parts[4];
         StringTrimLeft(fr);
         StringTrimRight(fr);
         out.freeze_orders = (fr == "1" || StringToInteger(fr) != 0);
         out.reason = parts[3];
        }
      else if(n >= 4)
        {
         string p3 = parts[3];
         StringTrimLeft(p3);
         StringTrimRight(p3);
         if(p3 == "0" || p3 == "1")
           {
            out.freeze_orders = (p3 == "1");
            out.reason = "外部AI";
           }
         else
            out.reason = p3;
        }
      else
         out.reason = "外部AI";

      out.from_external_ai = true;
      return true;
     }

   // ---- 新格式 DIR,CONF,FREEZE[,reason] ----
   if(!AutoJudge_ParseDirectionToken(p0, out.direction))
      return false;

   out.confidence = StringToDouble(parts[1]);
   if(out.confidence < 0.0) out.confidence = 0.0;
   if(out.confidence > 100.0) out.confidence = 100.0;

   string fr = parts[2];
   StringTrimLeft(fr);
   StringTrimRight(fr);
   out.freeze_orders = (fr == "1" || StringToInteger(fr) != 0);

   out.reason = (n >= 4 ? parts[3] : "DeepSeek");
   StringTrimLeft(out.reason);
   StringTrimRight(out.reason);
   AutoJudge_SetRegimeFromDir(out);
   out.from_external_ai = true;
   return true;
  }

bool AutoJudge_ReadExternal(JudgeResult &out, const int maxAgeSec)
  {
   string path = "ai\\signal.txt";
   if(!FileIsExist(path, FILE_COMMON))
      return false;

   datetime mtime = (datetime)FileGetInteger(path, FILE_MODIFY_DATE, FILE_COMMON);
   if(maxAgeSec > 0 && TimeCurrent() - mtime > maxAgeSec)
      return false;

   int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_UNICODE|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   string line = "";
   if(!FileIsEnding(h))
      line = FileReadString(h);
   FileClose(h);
   StringTrimLeft(line);
   StringTrimRight(line);
   if(line == "")
      return false;
   return AutoJudge_ParseExternal(line, out);
  }

bool AutoJudge_ApplyTeachKv(const string key, const string val, JudgeResult &out)
  {
   string k = key;
   StringToUpper(k);
   StringTrimLeft(k);
   StringTrimRight(k);
   string v = val;
   StringTrimLeft(v);
   StringTrimRight(v);
   if(k == "DIR")
     {
      ENUM_TREND_DIR d;
      if(AutoJudge_ParseDirectionToken(v, d))
         out.direction = d;
      AutoJudge_SetRegimeFromDir(out);
      return true;
     }
   if(k == "CONF")
     {
      out.confidence = StringToDouble(v);
      if(out.confidence < 0.0) out.confidence = 0.0;
      if(out.confidence > 100.0) out.confidence = 100.0;
      return true;
     }
   if(k == "FREEZE")
     {
      out.freeze_orders = (v == "1" || StringToInteger(v) != 0);
      return true;
     }
   if(k == "SHORT" || k == "REASON")
     {
      out.reason = v;
      return true;
     }
   if(k == "SUP1") { out.support1 = StringToDouble(v); return true; }
   if(k == "SUP2") { out.support2 = StringToDouble(v); return true; }
   if(k == "RES1") { out.resist1 = StringToDouble(v); return true; }
   if(k == "STEP_HINT") { out.step_hint = StringToDouble(v); return true; }
   if(k == "WHY_TREND") { out.why_trend = v; return true; }
   if(k == "WHY_SUP") { out.why_sup = v; return true; }
   if(k == "LESSON") { out.lesson = v; return true; }
   if(k == "M5_BAR" || k == "M1_BAR") { out.signal_bar = v; return true; }
   return false;
  }

bool AutoJudge_ReadTeach(JudgeResult &out, const int maxAgeSec)
  {
   string path = "ai\\teach.txt";
   if(!FileIsExist(path, FILE_COMMON))
      return AutoJudge_ReadExternal(out, maxAgeSec);

   datetime mtime = (datetime)FileGetInteger(path, FILE_MODIFY_DATE, FILE_COMMON);
   if(maxAgeSec > 0 && TimeCurrent() - mtime > maxAgeSec)
      return false;

   int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_UNICODE|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return AutoJudge_ReadExternal(out, maxAgeSec);

   AutoJudge_Clear(out);
   out.from_external_ai = true;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "")
         continue;
      int eq = StringFind(line, "=");
      if(eq <= 0)
         continue;
      string key = StringSubstr(line, 0, eq);
      string val = StringSubstr(line, eq + 1);
      AutoJudge_ApplyTeachKv(key, val, out);
     }
   FileClose(h);
   if(out.reason == "" && out.lesson != "")
      out.reason = out.lesson;
   if(out.reason == "")
      out.reason = "DeepSeek辅助";
   AutoJudge_SetRegimeFromDir(out);
   return true;
  }

void AutoJudge_ClearLevelObjects()
  {
   ObjectDelete(0, AI_OBJ_SUP1);
   ObjectDelete(0, AI_OBJ_SUP2);
   ObjectDelete(0, AI_OBJ_RES1);
  }

void AutoJudge_DrawHLine(const string name, const double price, const color clr, const string tip)
  {
   if(price <= 0.0)
     {
      ObjectDelete(0, name);
      return;
     }
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip + " " + DoubleToString(price, _Digits));
   ObjectSetString(0, name, OBJPROP_TEXT, tip);
  }

void AutoJudge_DrawLevels(const JudgeResult &j)
  {
   if(!j.from_external_ai)
     {
      AutoJudge_ClearLevelObjects();
      return;
     }
   AutoJudge_DrawHLine(AI_OBJ_SUP1, j.support1, clrDodgerBlue, "AI支撑1");
   AutoJudge_DrawHLine(AI_OBJ_SUP2, j.support2, clrDeepSkyBlue, "AI支撑2");
   AutoJudge_DrawHLine(AI_OBJ_RES1, j.resist1, clrOrangeRed, "AI压力");
  }

// EA 写行情快照，供 Python DeepSeek 桥读取（含近20根历史）
bool AutoJudge_WriteSnapshot(
   const string symbol,
   const double bid,
   const double ask,
   const int buyN,
   const int sellN,
   const double buyLot,
   const double sellLot,
   const double buyP,
   const double sellP,
   const double adx,
   const double rsi,
   const ENUM_TIMEFRAMES tf,
   const double range2h = 0.0,
   const double spread_max_2h = 0.0,
   const double ema5 = 0.0,
   const double ema10 = 0.0,
   const double ema20 = 0.0,
   const double ema5prev = 0.0,
   const string maState = "",
   const double macdMain = 0.0,
   const double macdSig = 0.0,
   const double stochK = 50.0,
   const double stochD = 50.0,
   const double userTp = 0.0,
   const double userSl = 0.0,
   const int openStartHHMM = 0,
   const int openEndHHMM = 0)
  {
   // 告诉桥：这台 Windows/Mac 的公共目录到底在哪（各终端数据目录都能扫到）
   string common = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
   int mark = FileOpen("ea_ai_dir.txt", FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(mark != INVALID_HANDLE)
     {
      FileWriteString(mark, common + "\\Files\\ai\n");
      FileClose(mark);
     }

   FolderCreate("ai", FILE_COMMON);
   int h = FileOpen("ai\\snapshot.txt",
                    FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
     {
      static datetime s_snap_fail = 0;
      if(TimeCurrent() - s_snap_fail >= 30)
        {
         PrintFormat("AI快照写失败 err=%d 公共目录=%s\\Files\\ai",
                     GetLastError(), common);
         s_snap_fail = TimeCurrent();
        }
      return false;
     }

   FileWriteString(h, StringFormat("SYMBOL=%s\n", symbol));
   FileWriteString(h, StringFormat("TIME=%s\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
   FileWriteString(h, StringFormat("TF=%s\n", EnumToString(tf)));
   FileWriteString(h, StringFormat("BID=%.5f\n", bid));
   FileWriteString(h, StringFormat("ASK=%.5f\n", ask));
   FileWriteString(h, StringFormat("SPREAD=%.5f\n", ask - bid));
   FileWriteString(h, StringFormat("BUY_N=%d\n", buyN));
   FileWriteString(h, StringFormat("SELL_N=%d\n", sellN));
   FileWriteString(h, StringFormat("BUY_LOT=%.2f\n", buyLot));
   FileWriteString(h, StringFormat("SELL_LOT=%.2f\n", sellLot));
   FileWriteString(h, StringFormat("BUY_P=%.2f\n", buyP));
   FileWriteString(h, StringFormat("SELL_P=%.2f\n", sellP));
   FileWriteString(h, StringFormat("ALL_P=%.2f\n", buyP + sellP));
   FileWriteString(h, StringFormat("SIDE_MAX=%d\n", MathMax(buyN, sellN)));
   FileWriteString(h, StringFormat("ADX=%.2f\n", adx));
   FileWriteString(h, StringFormat("RSI=%.2f\n", rsi));
   string barKey = (tf == PERIOD_M1 ? "M1" : "M5");
   FileWriteString(h, StringFormat("MA_TF=%s\n", EnumToString(tf)));
   FileWriteString(h, StringFormat("%s_BAR=%s\n", barKey,
                                   TimeToString(iTime(symbol, tf, 0), TIME_DATE|TIME_MINUTES)));
   FileWriteString(h, StringFormat("EMA5=%.5f\n", ema5));
   FileWriteString(h, StringFormat("EMA10=%.5f\n", ema10));
   FileWriteString(h, StringFormat("EMA20=%.5f\n", ema20));
   FileWriteString(h, StringFormat("EMA5_PREV=%.5f\n", ema5prev));
   FileWriteString(h, StringFormat("MA_STATE=%s\n", maState));
   int bull = 0, bear = 0, above = 0, below = 0;
   for(int k = 1; k <= 5; k++)
     {
      double o = iOpen(symbol, tf, k);
      double c = iClose(symbol, tf, k);
      double hi = iHigh(symbol, tf, k);
      double lo = iLow(symbol, tf, k);
      FileWriteString(h, StringFormat("%sO%d=%.5f\n", barKey, k, o));
      FileWriteString(h, StringFormat("%sC%d=%.5f\n", barKey, k, c));
      FileWriteString(h, StringFormat("%sH%d=%.5f\n", barKey, k, hi));
      FileWriteString(h, StringFormat("%sL%d=%.5f\n", barKey, k, lo));
      if(c > o) bull++;
      else if(c < o) bear++;
      if(ema5 > 0.0 && c > ema5) above++;
      else if(ema5 > 0.0 && c < ema5) below++;
     }
   double h1 = iHigh(symbol, tf, 1);
   double h5 = iHigh(symbol, tf, 5);
   double l1 = iLow(symbol, tf, 1);
   double l5 = iLow(symbol, tf, 5);
   string kState = "震荡";
   if(h1 > h5 && l1 > l5 && bull >= bear)
      kState = "上涨";
   else if(h1 < h5 && l1 < l5 && bear >= bull)
      kState = "下跌";
   string closeVs = "夹";
   if(above >= 4) closeVs = "上";
   else if(below >= 4) closeVs = "下";
   double macdHist = macdMain - macdSig;
   string oscState = "中性";
   if(rsi >= 70.0 || stochK >= 80.0)
      oscState = "超买";
   else if(rsi <= 30.0 || stochK <= 20.0)
      oscState = "超卖";
   // ADX 不够 20 一律当没走出方向，不因为 MACD 正负就判多空
   string trendState = "弱";
   if(adx >= 20.0 && macdHist > 0.0)
      trendState = "多";
   else if(adx >= 20.0 && macdHist < 0.0)
      trendState = "空";
   // 前三根已收盘 K 线的均价：(高+低+收)/3 再平均。超短线用传入的周期，现在是 M1。
   double avg3 = 0.0;
   int avgN = 0;
   for(int sw = 1; sw <= 3; sw++)
     {
      double hh = iHigh(symbol, tf, sw);
      double ll = iLow(symbol, tf, sw);
      double cc = iClose(symbol, tf, sw);
      if(hh <= 0.0 || ll <= 0.0 || cc <= 0.0)
         continue;
      avg3 += (hh + ll + cc) / 3.0;
      avgN++;
     }
   if(avgN == 3)
      avg3 /= 3.0;
   else
      avg3 = 0.0;
   // EA 不判方向，只把 5 分钟行情交给 DeepSeek。DIR_HINT 不是开仓指令。
   string dirHint = "请你判断";
   g_ai_ma_dir = 0;
   g_line_judge = "等待DeepSeek";
   FileWriteString(h, StringFormat("MACD=%.5f\n", macdMain));
   FileWriteString(h, StringFormat("MACD_SIG=%.5f\n", macdSig));
   FileWriteString(h, StringFormat("STOCH_K=%.2f\n", stochK));
   FileWriteString(h, StringFormat("STOCH_D=%.2f\n", stochD));
   FileWriteString(h, StringFormat("OSC_STATE=%s\n", oscState));
   FileWriteString(h, StringFormat("TREND_STATE=%s\n", trendState));
   FileWriteString(h, StringFormat("K_STATE=%s\n", kState));
   FileWriteString(h, StringFormat("K_BULL=%d\n", bull));
   FileWriteString(h, StringFormat("K_BEAR=%d\n", bear));
   FileWriteString(h, StringFormat("CLOSE_VS_EMA5=%s\n", closeVs));
   FileWriteString(h, StringFormat("AVG3=%.5f\n", avg3));
   FileWriteString(h, StringFormat("DIR_HINT=%s\n", dirHint));
   FileWriteString(h, "CONFIRM=0\n");
   int sh = openStartHHMM / 100;
   int sm = openStartHHMM % 100;
   int eh = openEndHHMM / 100;
   int em = openEndHHMM % 100;
   if(sh < 0) sh = 0;
   if(eh < 0) eh = 0;
   if(sh > 23) sh = 23;
   if(eh > 23) eh = 23;
   if(sm > 59) sm = 59;
   if(em > 59) em = 59;
   string openStartTxt = StringFormat("%02d:%02d", sh, sm);
   string openEndTxt = StringFormat("%02d:%02d", eh, em);
   if(openStartHHMM == openEndHHMM)
     {
      openStartTxt = "全天";
      openEndTxt = "全天";
     }
   FileWriteString(h, StringFormat("USER_TP=%.2f\n", userTp));
   FileWriteString(h, StringFormat("USER_SL=%.2f\n", userSl));
   FileWriteString(h, StringFormat("OPEN_START=%s\n", openStartTxt));
   FileWriteString(h, StringFormat("OPEN_END=%s\n", openEndTxt));
   FileWriteString(h, "TP_SL_SESSION=用户设定，不要修改\n");
   FileWriteString(h, StringFormat("RANGE_2H=%.5f\n", range2h));
   FileWriteString(h, StringFormat("SPREAD_MAX_2H=%.5f\n", spread_max_2h));

   // 近20根5分钟，给进场看针和纺锤。30分钟另写一套，给方向看整段。
   for(int i = 1; i <= 20; i++)
     {
      FileWriteString(h, StringFormat("C%d=%.5f\n", i, iClose(symbol, PERIOD_M5, i)));
      FileWriteString(h, StringFormat("H%d=%.5f\n", i, iHigh(symbol, PERIOD_M5, i)));
      FileWriteString(h, StringFormat("L%d=%.5f\n", i, iLow(symbol, PERIOD_M5, i)));
      FileWriteString(h, StringFormat("M30C%d=%.5f\n", i, iClose(symbol, PERIOD_M30, i)));
      FileWriteString(h, StringFormat("M30H%d=%.5f\n", i, iHigh(symbol, PERIOD_M30, i)));
      FileWriteString(h, StringFormat("M30L%d=%.5f\n", i, iLow(symbol, PERIOD_M30, i)));
     }
   FileClose(h);
   static bool s_snap_announced = false;
   if(!s_snap_announced)
     {
      PrintFormat("AI快照目录: %s\\Files\\ai", common);
      s_snap_announced = true;
     }
   return true;
  }

void AutoJudge_ApplyLeanDirection(
   const double score_up,
   const double score_down,
   const double lean_gap,
   JudgeResult &out,
   string &why)
  {
   double gap = MathMax(1.0, lean_gap);
   if(score_up >= score_down + gap)
     {
      out.direction = TREND_LEAN_UP;
      out.confidence = MathMin(88.0, 52.0 + (score_up - score_down));
      why += "→中性偏多";
     }
   else if(score_down >= score_up + gap)
     {
      out.direction = TREND_LEAN_DOWN;
      out.confidence = MathMin(88.0, 52.0 + (score_down - score_up));
      why += "→中性偏空";
     }
   else
     {
      out.direction = TREND_FLAT;
      out.confidence = MathMin(85.0, 50.0 + MathAbs(score_up - score_down) * 0.3);
      why += "→震荡中性";
     }
  }

// 近几根收盘是否与“趋势方向”相反（急跌后反弹 / 急涨后回落）
bool AutoJudge_ShortTermAgainst(const ENUM_TIMEFRAMES tf, const bool want_down, string &why)
  {
   double c1 = iClose(_Symbol, tf, 1);
   double c2 = iClose(_Symbol, tf, 2);
   double c3 = iClose(_Symbol, tf, 3);
   double c4 = iClose(_Symbol, tf, 4);
   if(c1 <= 0.0 || c2 <= 0.0 || c3 <= 0.0)
      return false;

   if(want_down)
     {
      bool higher = (c1 > c2 && c2 > c3);
      bool bounce = (c1 > c3 && c1 > c4 && c1 > c2);
      if(higher || bounce)
        {
         why += "短线反弹弱化空;";
         return true;
        }
     }
   else
     {
      bool lower = (c1 < c2 && c2 < c3);
      bool pullback = (c1 < c3 && c1 < c4 && c1 < c2);
      if(lower || pullback)
        {
         why += "短线回落弱化多;";
         return true;
        }
     }
   return false;
  }

// lean_gap: 多空分差达到该值则判「中性偏多/偏空」
bool AutoJudge_Builtin(
   const int adx_handle,
   const int ema_handle,
   const int rsi_handle,
   const int atr_handle,
   const double adx_trend,
   const double adx_range,
   const double lean_gap,
   const ENUM_TIMEFRAMES judge_tf,
   JudgeResult &out)
  {
   AutoJudge_Clear(out);

   double adx[], ema[], rsi[], atr[];
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(adx_handle, 0, 0, 3, adx) < 3)
      return false;
   if(CopyBuffer(ema_handle, 0, 0, 3, ema) < 3)
      return false;

   double rsi_v = 50.0;
   if(rsi_handle != INVALID_HANDLE && CopyBuffer(rsi_handle, 0, 0, 1, rsi) >= 1)
      rsi_v = rsi[0];

   double atr_now = 0.0, atr_avg = 0.0;
   if(atr_handle != INVALID_HANDLE && CopyBuffer(atr_handle, 0, 0, 20, atr) >= 20)
     {
      atr_now = atr[0];
      double s = 0.0;
      for(int i = 0; i < 20; i++) s += atr[i];
      atr_avg = s / 20.0;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double score_trend = 0.0;
   double score_up = 0.0;
   double score_down = 0.0;
   string why = "";

   if(adx[0] >= adx_trend)
     {
      score_trend += 35.0;
      why += "ADX强;";
     }
   else if(adx[0] <= adx_range)
     {
      score_trend -= 30.0;
      why += "ADX弱;";
     }
   else
     {
      score_trend += (adx[0] - adx_range) / MathMax(adx_trend - adx_range, 1.0) * 15.0;
      why += "ADX中;";
     }

   if(adx[0] > adx[1] && adx[1] >= adx[2])
     {
      score_trend += 8.0;
      why += "ADX抬升;";
     }
   else if(adx[0] < adx[1] && adx[1] <= adx[2])
     {
      score_trend -= 12.0;
      why += "ADX回落;";
     }

   bool ema_up = (ema[0] > ema[1] && bid > ema[0]);
   bool ema_dn = (ema[0] < ema[1] && bid < ema[0]);
   if(ema_up)
     {
      score_up += 28.0;
      why += "EMA多;";
     }
   else if(ema_dn)
     {
      score_down += 28.0;
      why += "EMA空;";
     }
   else
     {
      score_trend -= 12.0;
      why += "EMA乱;";
      if(ema[0] > ema[1]) score_up += 8.0;
      else if(ema[0] < ema[1]) score_down += 8.0;
     }

   if(ema[0] > 0.0)
     {
      double dist = MathAbs(bid - ema[0]);
      double stretch = (atr_avg > 0.0 ? dist / atr_avg : 0.0);
      if(stretch >= 2.0)
        {
         score_trend -= 15.0;
         why += "偏离均线过大;";
         if(bid < ema[0]) score_down -= 8.0;
         if(bid > ema[0]) score_up -= 8.0;
        }
     }

   if(rsi_v >= 70.0)
     {
      score_up -= 18.0;
      why += "RSI超买;";
     }
   else if(rsi_v <= 30.0)
     {
      score_down -= 18.0;
      why += "RSI超卖;";
     }
   else if(rsi_v >= 55.0)
      score_up += 6.0;
   else if(rsi_v <= 45.0)
      score_down += 6.0;

   if(atr_avg > 0.0)
     {
      double ratio = atr_now / atr_avg;
      if(ratio >= 1.5)
        {
         score_trend += 8.0;
         why += "波动放大;";
        }
      else if(ratio >= 1.3)
        {
         score_trend += 5.0;
         why += "波动偏大;";
        }
      else if(ratio <= 0.8)
        {
         score_trend -= 10.0;
         why += "波动收缩;";
        }
     }

   bool against_down = AutoJudge_ShortTermAgainst(judge_tf, true, why);
   bool against_up = AutoJudge_ShortTermAgainst(judge_tf, false, why);
   if(against_down)
      score_down -= 20.0;
   if(against_up)
      score_up -= 20.0;

   const double trend_need = 38.0;
   const double side_need  = 26.0;

   bool can_trend = (score_trend >= trend_need &&
                     (score_up >= side_need || score_down >= side_need));

   if(can_trend && score_up > score_down && !against_up)
     {
      out.regime = REGIME_TREND;
      out.direction = TREND_UP;
      out.confidence = MathMin(90.0, 50.0 + score_trend * 0.35 + score_up * 0.25);
      why += "→趋势偏多";
     }
   else if(can_trend && score_down > score_up && !against_down)
     {
      out.regime = REGIME_TREND;
      out.direction = TREND_DOWN;
      out.confidence = MathMin(90.0, 50.0 + score_trend * 0.35 + score_down * 0.25);
      why += "→趋势偏空";
     }
   else
     {
      out.regime = REGIME_RANGE;
      AutoJudge_ApplyLeanDirection(score_up, score_down, lean_gap, out, why);
      if(against_down && out.direction == TREND_LEAN_DOWN)
         why += "(反弹降级)";
      if(against_up && out.direction == TREND_LEAN_UP)
         why += "(回落降级)";
     }

   out.reason = why;
   return true;
  }

string AutoJudge_DirText(const ENUM_TREND_DIR d)
  {
   if(d == TREND_UP) return "上涨趋势";
   if(d == TREND_DOWN) return "下跌趋势";
   if(d == TREND_LEAN_UP) return "中性偏多";
   if(d == TREND_LEAN_DOWN) return "中性偏空";
   return "中性";
  }

string AutoJudge_ToComment(const JudgeResult &j)
  {
   string mode = (j.regime == REGIME_TREND ? "趋势跟随" : "网格震荡");
   string dir  = AutoJudge_DirText(j.direction);
   string src  = (j.from_external_ai ? "外部AI辅助" : "内置研判");
   string fr   = (j.freeze_orders ? "建议先别加" : "可参考开仓");
   string s1 = (j.support1 > 0.0 ? DoubleToString(j.support1, _Digits) : "-");
   string body = j.reason;
   if(j.why_trend != "")
      body += "\n为何趋势: " + j.why_trend;
   if(j.why_sup != "")
      body += "\n支撑为何: " + j.why_sup;
   if(j.lesson != "")
      body += "\n课堂: " + j.lesson;
   return StringFormat("%s | %s | 方向:%s | 置信度:%.0f%% | %s | 支撑%s\n%s",
                       src, mode, dir, j.confidence, fr, s1, body);
  }

#endif
//+------------------------------------------------------------------+

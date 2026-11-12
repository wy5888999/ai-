//+------------------------------------------------------------------+
//|                                              XAUUSD_Grid_EA.mq5  |
//| DeepSeek一单一结：一根M5只做一单；止盈止损和开仓时段用用户参数 |
//+------------------------------------------------------------------+
#property copyright "xauusd-quant"
#property version   "7.14"
#property strict

// 本机与分享包都带 AI：DeepSeek 只给方向；止盈、止损、开仓时段用下面的用户参数
#define EA_BUILD_WITH_AI
// Windows 包编译前打开下一行；Mac 包保持注释（大面板）
//#define EA_PANEL_WIN

#include <Trade\Trade.mqh>
#include <AI\NewsCalendar.mqh>
#include <AI\AutoJudge.mqh>

//---------------- 纯马丁 ----------------
input group "=== 【一】纯马丁 ==="
input double          InitLot              = 0.01;    // 起手手数(0=不开仓)
input double          MartinMult           = 1.3;     // 马丁倍率(<=0 或 <1 时按1处理；建议>=1)
input double          GridStepUSD          = 1.0;     // 逆势加仓间距美金(0=不加仓；封顶15层内共用)
input bool            ManualOpenNeedSpacing = false;  // 手开/指令补仓也要间距(关=可随时手补，不拒开防连单)
input int             AddCooldownSec       = 15;      // 加仓冷却秒(0=无冷却，立即允许下一笔判断)
input int             MaxLayers            = 15;      // 单边封顶层数(默认15；0=禁止一切开仓/加仓)
input double          BasketTP             = 50.0;    // 单边篮子止盈USC(0=不止盈)
input double          BasketSL_Money       = -4500.0; // 总止损USC(0或正数=不止损；负数为阈值)
input int             BasketSL_CooldownSec = 1800;   // 止损后冷却秒(0=止损后立即允许再开)
input bool            UseProfitTrailLock   = true;    // 浮盈锁利：峰值回撤后若扣去止损额仍有赚→全平
input double          ProfitTrailUSD       = 0;       // 锁利回撤USC(0=用总止损绝对值)
input int             OpenStartHHMM        = 0;       // 开仓开始北京时间HHMM(800=08:00；与结束相同=全天)
input int             OpenEndHHMM          = 0;       // 开仓结束北京时间HHMM(2200=22:00；小于开始=跨夜)
// 兼容旧图表参数（已废弃，固定多空双边马丁）
input int             MartinDirection      = 2;       // 废弃：固定双边，忽略
input int             GridDirection        = 2;       // 废弃
input bool            FirstBothSides       = true;    // 废弃：始终双边首仓

// 对冲已关闭（面板/参数均不提供）
#define HedgeAfterLayers  0
#define HedgeLotMult      2.0
#define HedgeSkipGapUSD   3.0

//---------------- 新闻（美高影响：进窗口先清空持仓，窗口内不开新仓） ----------------
input group "=== 【二】新闻 ==="
input bool            UseNewsFilter        = true;    // 开：新闻窗口清仓+禁开
input int             NewsBeforeMin        = 30;      // 新闻前多少分钟进入窗口
input int             NewsAfterMin         = 15;      // 新闻后多少分钟仍冻结
input int             NewsRefreshSec       = 30;

//---------------- 公共 ----------------
input group "=== 【三】公共 ==="
input int             MagicBase            = 88000;
input string          OrderCommentText     = "美分马丁";
input int             MaxSpreadPoints      = 5000;
input string          BgImageFile          = "";      // 背景图(放MQL5\Images下的bmp,空=不用)

//---------------- 多账号共享配置 ----------------
input group "=== 【四】共享配置(多账号) ==="
input bool            UseSharedConfig      = true;    // 启用后走Common共享文件
input bool            SharedConfigMaster   = false;   // 仅1个号勾选主号(改参数的那个)
input string          SharedConfigFile     = "XAU_Martin_Shared.cfg";
input int             SharedConfigReloadSec = 3;      // 从号重读间隔秒
input string          SharedEntryFile      = "XAU_Martin_Entry.sig"; // 主号指令总线(开/平/暂停)

#ifdef EA_BUILD_WITH_AI
//---------------- DeepSeek 只判断方向；止盈止损、开仓时段用【一】里你设的参数 ----------------
input group "=== 【五】DeepSeek方向(止盈止损与开仓时段不由AI改) ==="
input bool            UseExternalAI        = true;    // 读 Common\Files\ai 方向（关=不用AI）
input bool            AiAutoOpen           = true;    // 方向确定后自动开首仓(关=只显示，仍可手开)
input int             AiSnapshotSec        = 5;       // 写行情快照间隔秒
input int             AiSignalMaxAgeSec    = 300;     // 教学文件最大有效秒(过期不显示)
input ENUM_TIMEFRAMES AiJudgeTF            = PERIOD_M5; // 方向已固定看M5收盘，改这项不影响判断
#endif

CTrade   trade;

// 运行时参数（共享配置写入/读出；交易逻辑只用这些，不用 input 原值）
double g_InitLot = 0.01;
double g_MartinMult = 1.3;
int    g_MartinDirection = 2;          // 固定2=双边（兼容旧共享文件）
double g_GridStepUSD = 1.0;
int    g_AddCooldownSec = 15;
int    g_MaxLayers = 15;               // 单边封顶层数
double g_BasketTP = 50.0;              // 单边篮子止盈USC（多空各自判断）
double g_BasketSL_Money = -4500.0;
int    g_BasketSL_CooldownSec = 1800;  // 30分钟
bool   g_UseProfitTrailLock = true;
double g_ProfitTrailUSD = 0.0;         // 0=跟止损绝对值
int    g_OpenStartHHMM = 0;            // 开仓开始，北京 HHMM
int    g_OpenEndHHMM = 0;              // 开仓结束，北京 HHMM
double g_peak_all_profit = 0.0;        // 本轮持仓最高总浮盈
bool   g_UseNewsFilter = true;
int    g_NewsBeforeMin = 30;
int    g_NewsAfterMin = 15;
int    g_MaxSpreadPoints = 5000;
datetime g_shared_last_load = 0;
datetime g_shared_last_write = 0;
string   g_shared_last_sig = "";
datetime g_lastAddTime      = 0;       // 兼容旧逻辑
datetime g_lastAddBuy       = 0;
datetime g_lastAddSell      = 0;
datetime g_sl_pause_until   = 0;
bool     g_pause_buy        = false;
bool     g_pause_sell       = false;
bool     g_news_was_frozen  = false;   // 用于检测「刚进入新闻窗口」
double   g_day_start_equity = 0.0;
int      g_session_day_key  = 0;
int      g_hedge_against    = -1;      // POSITION_TYPE_* 被对冲的重仓边
long     g_spread_max_2h_pts = 0;
#ifdef EA_BUILD_WITH_AI
datetime g_ai_last_snapshot  = 0;
datetime g_ai_last_load      = 0;
datetime g_ai_opened_bar     = 0;      // 已按这根已收盘M5开过，同根不再开
datetime g_ai_entry_bar      = 0;      // AI仓所在的那根M5，这根走完就平
bool     g_manual_hold       = false;  // 人工单只靠止盈止损，不在M5结束时平
JudgeResult g_ai_judge;
int      g_ai_hold_side = 0;   // 已经站住的方向，一根信号不让它翻
int      g_ai_flip_side = 0;
int      g_ai_flip_hits = 0;
datetime g_ai_seen_teach = 0;
int      g_entry_arm_side = 0;
int      g_entry_arm_hits = 0;
bool     g_range_trade = false;
double   g_chop_hi = 0.0;
double   g_chop_lo = 0.0;
double   g_chop_pts = 0.0;
double   g_box_hi = 0.0;
double   g_box_lo = 0.0;
#ifdef EA_PANEL_WIN
#define AI_PANEL_LINE_MAX 2
#else
#define AI_PANEL_LINE_MAX 7
#endif
string   g_ai_panel_lines[AI_PANEL_LINE_MAX];
int      g_ai_panel_n        = 0;
int      g_ai_adx_handle     = INVALID_HANDLE;
int      g_ai_rsi_handle     = INVALID_HANDLE;
int      g_ai_ema5_handle    = INVALID_HANDLE;
int      g_ai_ema10_handle   = INVALID_HANDLE;
int      g_ai_ema20_handle   = INVALID_HANDLE;
#endif
int      g_chart_short_ma   = INVALID_HANDLE;
int      g_chart_macd      = INVALID_HANDLE;
int      g_chart_adx       = INVALID_HANDLE;
int      g_chart_rsi       = INVALID_HANDLE;
double   g_panel_rsi       = 0.0;
int      g_chart_stoch     = INVALID_HANDLE;
bool     g_trend_osc_on    = false;
datetime g_spread_window_start = 0;
long     g_applied_cmd_id = 0;         // 已执行过的主号指令
bool     g_cmd_watermark_ready = false; // Common 队列水位是否已可靠对齐
string   g_last_close_info = "尚未平过单笔"; // 上次平#1结果
color    g_last_close_col  = C'190,198,210';

#define BTN_ENTRY_BUY   "XAU_BTN_ENTRY_BUY"
#define BTN_ENTRY_SELL  "XAU_BTN_ENTRY_SELL"
#define BTN_ENTRY       "XAU_BTN_ENTRY"      // 旧按钮名，清理用
#define BTN_PAUSE       "XAU_BTN_PAUSE"
#define BTN_PAUSE_BUY   "XAU_BTN_PAUSE_BUY"
#define BTN_PAUSE_SELL  "XAU_BTN_PAUSE_SELL"
#define BTN_CLOSE_BUY   "XAU_BTN_CLOSE_BUY"
#define BTN_CLOSE_SELL  "XAU_BTN_CLOSE_SELL"
#define BTN_CLOSE_FIRST_BUY  "XAU_BTN_CLOSE_FIRST_BUY"
#define BTN_CLOSE_FIRST_SELL "XAU_BTN_CLOSE_FIRST_SELL"
#define BTN_CLOSE_ALL   "XAU_BTN_CLOSE_ALL"
#ifdef EA_PANEL_WIN
#define UI_POS_LIST_MAX 2
#else
#define UI_POS_LIST_MAX 4
#endif
#define BTN_TP_APPLY    "XAU_BTN_TP_APPLY"
#define BTN_TP_MINUS    "XAU_BTN_TP_MINUS"
#define BTN_TP_PLUS     "XAU_BTN_TP_PLUS"
#define BTN_SL_APPLY    "XAU_BTN_SL_APPLY"
#define BTN_SL_MINUS    "XAU_BTN_SL_MINUS"
#define BTN_SL_PLUS     "XAU_BTN_SL_PLUS"
#define BTN_LOT_APPLY   "XAU_BTN_LOT_APPLY"
#define BTN_LOT_MINUS   "XAU_BTN_LOT_MINUS"
#define BTN_LOT_PLUS    "XAU_BTN_LOT_PLUS"
#define BTN_SIDE_APPLY  "XAU_BTN_SIDE_APPLY"
#define EDIT_TP         "XAU_EDIT_TP"
#define EDIT_SL         "XAU_EDIT_SL"
#define EDIT_LOT        "XAU_EDIT_LOT"
#define EDIT_TP_BUY     "XAU_EDIT_TP_BUY"
#define EDIT_TP_SELL    "XAU_EDIT_TP_SELL"
#define UI_PANEL_BG     "XAU_UI_PANEL_BG"
#define UI_PANEL_FILL   "XAU_UI_PANEL_FILL"
#define UI_MID_FILL     "XAU_UI_MID_FILL"
#define UI_LIST_FILL    "XAU_UI_LIST_FILL"
#define UI_BG_BMP       "XAU_UI_BG_BMP"
#define UI_PREFIX       "XAU_UI_L_"
#define UI_CARD_PL      "XAU_UI_CARD_PL"
#define UI_CARD_ACC     "XAU_UI_CARD_ACC"
#define UI_CARD_BUY     "XAU_UI_CARD_BUY"
#define UI_CARD_SELL    "XAU_UI_CARD_SELL"
#define UI_FRAME_T      "XAU_UI_FRAME_T"
#define UI_FRAME_B      "XAU_UI_FRAME_B"
#define UI_FRAME_L      "XAU_UI_FRAME_L"
#define UI_FRAME_R      "XAU_UI_FRAME_R"
#define UI_OUT_T        "XAU_UI_OUT_T"
#define UI_OUT_B        "XAU_UI_OUT_B"
#define UI_OUT_L        "XAU_UI_OUT_L"
#define UI_OUT_R        "XAU_UI_OUT_R"
#define UI_FONT         "Microsoft YaHei UI"
#ifdef EA_PANEL_WIN
#define UI_FONT_SIZE    16
#define UI_TITLE_SIZE   18
#define UI_SMALL_SIZE   14
#define UI_BIG_SIZE     20
#define UI_PANEL_W      560
#define UI_PANEL_H_MIN  480
#define UI_LINE_STEP    34
#define UI_CTRL_H       36
#define UI_BTN_H        42
#define UI_BTN_W        120
#define UI_BTN_FONT     16
#define UI_EDIT_FONT    16
#define UI_MINI_FONT    14
#define UI_ROW          34
#define UI_BTN_GAP      8
#define UI_BTN_ALL_TEXT "全平"
#else
#define UI_FONT_SIZE    15
#define UI_TITLE_SIZE   18
#define UI_SMALL_SIZE   14
#define UI_BIG_SIZE     26
#define UI_PANEL_W      920
#define UI_PANEL_H_MIN  620
#define UI_LINE_STEP    32
#define UI_CTRL_H       36
#define UI_BTN_H        46
#define UI_BTN_W        112
#define UI_BTN_FONT     16
#define UI_EDIT_FONT    15
#define UI_MINI_FONT    14
#define UI_ROW          36
#define UI_BTN_GAP      10
#define UI_BTN_ALL_TEXT "全部平仓"
#endif
#define BTN_CLOSE_SIDE  "XAU_BTN_CLOSE_SIDE"
#define ENTRY_FILE_DEFAULT "XAU_Martin_Entry.sig"
#define CMD_QUEUE_MAX_PENDING 20
#define CMD_QUEUE_KEEP_LINES  120
#define CMD_FOLLOW_MAX_OPEN_PER_TICK 1   // 从号每 tick 最多跟 1 笔开仓，防队列追赶时一次灌十几单
#define CMD_APPLIED_FILE_PREFIX "XAU_Martin_CmdApplied_"
#define UI_COL_BG       C'24,28,36'
#define UI_COL_CARD     C'32,38,48'
#define UI_COL_BORDER   C'90,100,120'
#define UI_COL_TITLE    C'255,210,60'
#define UI_COL_MUTED    C'190,198,210'
#define UI_COL_TEXT     C'245,248,252'
#define UI_COL_GREEN    C'80,230,130'
#define UI_COL_RED      C'255,95,95'
#define UI_COL_BUYBD    C'50,180,100'
#define UI_COL_SELLBD   C'220,80,80'
bool     g_chart_theme_done = false;
bool     g_tp_edit_focus    = false;
bool     g_sl_edit_focus    = false;
bool     g_lot_edit_focus   = false;
bool     g_side_edit_focus  = false;
bool     g_ui_controls_ready = false;
datetime g_last_ui_refresh  = 0;
string   g_last_open_fail   = "";
int      g_ui_btn_y         = 280;
int      g_ui_panel_h       = 380;

int ResolvedMartinDirection(); // 面板/按钮用
bool OpenFirstIfEmpty(const int posType, const ENUM_ORDER_TYPE orderType, const string tag);
bool CloseFirstOfSide(const int posType, const string reason);
int  CollectGridTicketsOldestFirst(const int posType, ulong &tickets[], const int maxN);

//+------------------------------------------------------------------+
double UsdToPrice(const double usd) { return usd; }

datetime BeijingTime()
  {
   return TimeGMT() + 8 * 3600;
  }

int BeijingHHMM()
  {
   MqlDateTime dt;
   TimeToStruct(BeijingTime(), dt);
   return dt.hour * 100 + dt.min;
  }

int NormalizeHHMM(const int hhmm)
  {
   int v = hhmm;
   if(v < 0) v = 0;
   int h = v / 100;
   int m = v % 100;
   if(h > 23) h = 23;
   if(m > 59) m = 59;
   return h * 100 + m;
  }

string FormatHHMM(const int hhmm)
  {
   int v = NormalizeHHMM(hhmm);
   return StringFormat("%02d:%02d", v / 100, v % 100);
  }

string OpenSessionText()
  {
   int a = NormalizeHHMM(g_OpenStartHHMM);
   int b = NormalizeHHMM(g_OpenEndHHMM);
   if(a == b)
      return "全天";
   return FormatHHMM(a) + "-" + FormatHHMM(b);
  }

// 开始=结束（含 0 和 0）表示全天。结束小于开始表示跨过午夜。
bool InOpenSession()
  {
   int start = NormalizeHHMM(g_OpenStartHHMM);
   int end = NormalizeHHMM(g_OpenEndHHMM);
   if(start == end)
      return true;
   int now = BeijingHHMM();
   if(start < end)
      return (now >= start && now < end);
   return (now >= start || now < end);
  }

bool AiDrivesEntry()
  {
#ifdef EA_BUILD_WITH_AI
   return (UseExternalAI && AiAutoOpen);
#else
   return false;
#endif
  }

// AI 窗口还开着才允许自动下单。关窗口会把 alive.txt 写成 OFF。
// 旧桥没有这个文件时，教学文件 3 分钟内还在更新才算还开着。
bool AiBridgeOn()
  {
#ifdef EA_BUILD_WITH_AI
   string alive = "ai\\alive.txt";
   if(FileIsExist(alive, FILE_COMMON))
     {
      datetime mtime = (datetime)FileGetInteger(alive, FILE_MODIFY_DATE, FILE_COMMON);
      if(mtime <= 0 || TimeCurrent() - mtime > 180)
         return false;
      int h = FileOpen(alive, FILE_READ|FILE_TXT|FILE_UNICODE|FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      string line = FileReadString(h);
      FileClose(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      StringToUpper(line);
      if(StringFind(line, "OFF") >= 0)
         return false;
      return (StringFind(line, "ON") >= 0);
     }

   string teach = "ai\\teach.txt";
   if(FileIsExist(teach, FILE_COMMON))
     {
      datetime mt = (datetime)FileGetInteger(teach, FILE_MODIFY_DATE, FILE_COMMON);
      if(mt > 0 && TimeCurrent() - mt <= 180)
         return true;
     }
   string sig = "ai\\signal.txt";
   if(FileIsExist(sig, FILE_COMMON))
     {
      datetime mt2 = (datetime)FileGetInteger(sig, FILE_MODIFY_DATE, FILE_COMMON);
      if(mt2 > 0 && TimeCurrent() - mt2 <= 180)
         return true;
     }
   return false;
#else
   return false;
#endif
  }

int BeijingDayKey()
  {
   MqlDateTime dt;
   TimeToStruct(BeijingTime(), dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

void CfgCopyFromInputs()
  {
   g_InitLot = InitLot;
   g_MartinMult = MartinMult;
   g_MartinDirection = 2; // 固定多空双边
   g_GridStepUSD = GridStepUSD;
   g_AddCooldownSec = MathMax(0, AddCooldownSec);
   g_MaxLayers = MathMax(0, MaxLayers); // 0=禁止开仓
   g_BasketTP = BasketTP;
   if(g_BasketTP < 0.0) g_BasketTP = 0.0; // 0=不止盈
   g_BasketSL_Money = BasketSL_Money;
   g_BasketSL_CooldownSec = BasketSL_CooldownSec;
   g_UseProfitTrailLock = UseProfitTrailLock;
   g_ProfitTrailUSD = MathMax(0.0, ProfitTrailUSD);
   g_OpenStartHHMM = NormalizeHHMM(OpenStartHHMM);
   g_OpenEndHHMM = NormalizeHHMM(OpenEndHHMM);
   g_UseNewsFilter = UseNewsFilter;
   g_NewsBeforeMin = NewsBeforeMin;
   g_NewsAfterMin = NewsAfterMin;
   g_MaxSpreadPoints = MaxSpreadPoints;
  }

string CfgSignature()
  {
   // 含 Paused：主号只改暂停时从号也能靠签名变化立刻感知（不只靠 3 秒轮询里的字段）
   return StringFormat(
      "%.4f|%.4f|%d|%.4f|%d|%d|%.2f|%.2f|%d|%d|%d|%d|%d|%d|%d|%d",
      g_InitLot, g_MartinMult, 2,
      g_GridStepUSD,
      g_AddCooldownSec, g_MaxLayers, g_BasketTP, g_BasketSL_Money, g_BasketSL_CooldownSec,
      (int)g_UseNewsFilter, g_NewsBeforeMin, g_NewsAfterMin, g_MaxSpreadPoints,
      BotFullyPaused() ? 1 : 0,
      g_OpenStartHHMM, g_OpenEndHHMM);
  }

bool CfgInputsChangedVsRuntime()
  {
   if(MathAbs(InitLot - g_InitLot) > 1e-8) return true;
   if(MathAbs(MartinMult - g_MartinMult) > 1e-8) return true;
   if(MathAbs(GridStepUSD - g_GridStepUSD) > 1e-8) return true;
   if(AddCooldownSec != g_AddCooldownSec) return true;
   if(MaxLayers != g_MaxLayers) return true;
   if(MathAbs(BasketTP - g_BasketTP) > 1e-8) return true;
   if(MathAbs(BasketSL_Money - g_BasketSL_Money) > 1e-8) return true;
   if(BasketSL_CooldownSec != g_BasketSL_CooldownSec) return true;
   if(UseProfitTrailLock != g_UseProfitTrailLock) return true;
   if(MathAbs(ProfitTrailUSD - g_ProfitTrailUSD) > 1e-8) return true;
   if(NormalizeHHMM(OpenStartHHMM) != g_OpenStartHHMM) return true;
   if(NormalizeHHMM(OpenEndHHMM) != g_OpenEndHHMM) return true;
   if(UseNewsFilter != g_UseNewsFilter) return true;
   if(NewsBeforeMin != g_NewsBeforeMin) return true;
   if(NewsAfterMin != g_NewsAfterMin) return true;
   if(MaxSpreadPoints != g_MaxSpreadPoints) return true;
   return false;
  }

bool CfgWriteShared()
  {
   if(!UseSharedConfig)
      return false;
   string name = SharedConfigFile;
   StringTrimLeft(name);
   StringTrimRight(name);
   if(StringLen(name) <= 0)
      name = "XAU_Martin_Shared.cfg";

   int h = FileOpen(name, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("共享配置写入失败: %s err=%d", name, GetLastError());
      return false;
     }
   FileWriteString(h, "# XAU Martin shared config\n");
   FileWriteString(h, StringFormat("InitLot=%.4f\n", g_InitLot));
   FileWriteString(h, StringFormat("MartinMult=%.4f\n", g_MartinMult));
   FileWriteString(h, "MartinDirection=2\n"); // 2=双边固定
   FileWriteString(h, StringFormat("GridStepUSD=%.4f\n", g_GridStepUSD));
   FileWriteString(h, StringFormat("AddCooldownSec=%d\n", g_AddCooldownSec));
   FileWriteString(h, StringFormat("MaxLayers=%d\n", g_MaxLayers));
   FileWriteString(h, StringFormat("BasketTP=%.2f\n", g_BasketTP));
   FileWriteString(h, StringFormat("BasketSL_Money=%.2f\n", g_BasketSL_Money));
   FileWriteString(h, StringFormat("BasketSL_CooldownSec=%d\n", g_BasketSL_CooldownSec));
   FileWriteString(h, StringFormat("OpenStartHHMM=%d\n", g_OpenStartHHMM));
   FileWriteString(h, StringFormat("OpenEndHHMM=%d\n", g_OpenEndHHMM));
   FileWriteString(h, StringFormat("UseNewsFilter=%d\n", (int)g_UseNewsFilter));
   FileWriteString(h, StringFormat("NewsBeforeMin=%d\n", g_NewsBeforeMin));
   FileWriteString(h, StringFormat("NewsAfterMin=%d\n", g_NewsAfterMin));
   FileWriteString(h, StringFormat("MaxSpreadPoints=%d\n", g_MaxSpreadPoints));
   FileWriteString(h, StringFormat("Paused=%d\n", BotFullyPaused() ? 1 : 0));
   FileWriteString(h, StringFormat("Updated=%s\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
   FileWriteString(h, StringFormat("MasterLogin=%s\n", IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))));
   FileClose(h);
   g_shared_last_write = TimeCurrent();
   g_shared_last_sig = CfgSignature();
   return true;
  }

bool CfgReadShared()
  {
   if(!UseSharedConfig)
      return false;
   string name = SharedConfigFile;
   StringTrimLeft(name);
   StringTrimRight(name);
   if(StringLen(name) <= 0)
      name = "XAU_Martin_Shared.cfg";

   if(!FileIsExist(name, FILE_COMMON))
      return false;

   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;

   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) <= 0 || StringGetCharacter(line, 0) == '#')
         continue;
      int eq = StringFind(line, "=");
      if(eq <= 0)
         continue;
      string k = StringSubstr(line, 0, eq);
      string v = StringSubstr(line, eq + 1);
      StringTrimLeft(k); StringTrimRight(k);
      StringTrimLeft(v); StringTrimRight(v);
      if(k == "InitLot") g_InitLot = StringToDouble(v);
      else if(k == "MartinMult") g_MartinMult = StringToDouble(v);
      else if(k == "MartinDirection") g_MartinDirection = 2; // 忽略旧值，固定双边
      else if(k == "GridStepUSD" || k == "GridStepUSD_1_20")
         g_GridStepUSD = StringToDouble(v); // 兼容旧 cfg；21_50/After50 废弃忽略
      else if(k == "AddCooldownSec") g_AddCooldownSec = (int)StringToInteger(v);
      else if(k == "MaxLayers") g_MaxLayers = MathMax(0, (int)StringToInteger(v)); // 0=禁止开仓
      else if(k == "BasketTP") g_BasketTP = StringToDouble(v);
      else if(k == "BasketTP_LotsLE2") g_BasketTP = StringToDouble(v); // 兼容旧cfg
      else if(k == "BasketSL_Money") g_BasketSL_Money = StringToDouble(v);
      else if(k == "BasketSL_CooldownSec") g_BasketSL_CooldownSec = MathMax(0, (int)StringToInteger(v));
      else if(k == "OpenStartHHMM") g_OpenStartHHMM = NormalizeHHMM((int)StringToInteger(v));
      else if(k == "OpenEndHHMM") g_OpenEndHHMM = NormalizeHHMM((int)StringToInteger(v));
      else if(k == "UseNewsFilter") g_UseNewsFilter = ((int)StringToInteger(v) != 0);
      else if(k == "NewsBeforeMin") g_NewsBeforeMin = (int)StringToInteger(v);
      else if(k == "NewsAfterMin") g_NewsAfterMin = (int)StringToInteger(v);
      else if(k == "MaxSpreadPoints") g_MaxSpreadPoints = (int)StringToInteger(v);
      else if(k == "Paused")
        {
         // 从号跟主号暂停状态（主号重挂EA清掉暂停后，从号靠这里同步恢复）
         bool paused = ((int)StringToInteger(v) != 0);
         g_pause_buy = paused;
         g_pause_sell = paused;
        }
     }
   FileClose(h);
   if(g_BasketTP < 0.0) g_BasketTP = 0.0;
   g_MartinDirection = 2;
   g_shared_last_load = TimeCurrent();
   g_shared_last_sig = CfgSignature();
   return true;
  }

// 从号每 tick 轻量同步暂停位（不重读全部参数），避免主号已恢复从号还停着
bool CfgPullPausedOnly()
  {
   if(!UseSharedConfig || SharedConfigMaster)
      return false;
   string name = SharedConfigFile;
   StringTrimLeft(name);
   StringTrimRight(name);
   if(StringLen(name) <= 0)
      name = "XAU_Martin_Shared.cfg";
   if(!FileIsExist(name, FILE_COMMON))
      return false;
   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   bool found = false;
   bool paused = false;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) <= 0 || StringGetCharacter(line, 0) == '#')
         continue;
      int eq = StringFind(line, "=");
      if(eq <= 0)
         continue;
      string k = StringSubstr(line, 0, eq);
      string v = StringSubstr(line, eq + 1);
      StringTrimLeft(k); StringTrimRight(k);
      StringTrimLeft(v); StringTrimRight(v);
      if(k == "Paused")
        {
         paused = ((int)StringToInteger(v) != 0);
         found = true;
        }
     }
   FileClose(h);
   if(!found)
      return false;
   bool was = BotFullyPaused();
   g_pause_buy = paused;
   g_pause_sell = paused;
   if(was != BotFullyPaused())
     {
      Print(BotFullyPaused() ? "共享暂停位：已暂停" : "共享暂停位：已恢复");
      RefreshPanelButtons();
      return true;
     }
   return false;
  }

void CfgSyncRuntime()
  {
   if(!UseSharedConfig)
      return;

   string name = SharedConfigFile;
   StringTrimLeft(name);
   StringTrimRight(name);
   if(StringLen(name) <= 0)
      name = "XAU_Martin_Shared.cfg";

   if(SharedConfigMaster)
     {
      // 主号：F7改了 input → 写共享文件
      if(CfgInputsChangedVsRuntime())
        {
         CfgCopyFromInputs();
         if(CfgWriteShared())
            Print("共享配置已更新(主号改参)");
        }
      else
        {
         string sig = CfgSignature();
         if(sig != g_shared_last_sig)
           {
            if(CfgWriteShared())
               Print("共享配置已更新(运行时)");
           }
        }
     }
   else
     {
      // 暂停位每 tick 已在 OnTick 拉过；这里按间隔同步其余参数
      int gap = MathMax(1, SharedConfigReloadSec);
      if(g_shared_last_load > 0 && TimeCurrent() - g_shared_last_load < gap)
         return;
      bool wasPaused = BotFullyPaused();
      string oldSig = g_shared_last_sig;
      if(CfgReadShared())
        {
         if(oldSig != "" && oldSig != g_shared_last_sig)
            Print("共享配置已跟随主号更新");
         if(wasPaused != BotFullyPaused())
           {
            Print(BotFullyPaused() ? "共享配置：已暂停" : "共享配置：已恢复");
            RefreshPanelButtons();
           }
        }
     }
  }

void CfgInitShared()
  {
   CfgCopyFromInputs();
   if(!UseSharedConfig)
     {
      g_shared_last_sig = CfgSignature();
      return;
     }

   string name = SharedConfigFile;
   StringTrimLeft(name);
   StringTrimRight(name);
   if(StringLen(name) <= 0)
      name = "XAU_Martin_Shared.cfg";

   if(!FileIsExist(name, FILE_COMMON))
     {
      // 首次：用默认/当前input写出，之后大家跟这份跑
      if(CfgWriteShared())
         PrintFormat("共享配置首次创建: Common\\\\Files\\\\%s", name);
     }
   else
     {
      if(CfgReadShared())
         PrintFormat("已加载共享配置: Common\\\\Files\\\\%s (%s)",
                     name, (SharedConfigMaster ? "主号" : "从号"));
     }
  }

double DayPnL_Total()
  {
   // 已实现+浮盈 ≈ 当前净值 - 当日开盘净值基准（北京日）
   if(g_day_start_equity <= 0.0)
      return 0.0;
   return AccountInfoDouble(ACCOUNT_EQUITY) - g_day_start_equity;
  }

bool UiSameSymbol(const string a, const string b)
  {
   string x = a, y = b;
   StringToUpper(x);
   StringToUpper(y);
   return (x == y);
  }

bool IsOurClosedDeal(const ulong d)
  {
   if(d == 0)
      return false;
   if(!UiSameSymbol(HistoryDealGetString(d, DEAL_SYMBOL), _Symbol))
      return false;
   long magic = HistoryDealGetInteger(d, DEAL_MAGIC);
   if(magic == MagicBase)
      return true;
   // 部分平仓/手工平可能丢 magic，用注释兜底
   string cmt = HistoryDealGetString(d, DEAL_COMMENT);
   if(StringLen(OrderCommentText) > 0 && StringFind(cmt, OrderCommentText) >= 0)
      return true;
   if(StringFind(cmt, "美分马丁") >= 0 || StringFind(cmt, "ENTRY_") >= 0 ||
      StringFind(cmt, "ADD_") >= 0 || StringFind(cmt, "HEDGE") >= 0 ||
      StringFind(cmt, "专家") >= 0 || StringFind(cmt, "AI下单") >= 0 ||
      StringFind(cmt, "人工") >= 0 || StringFind(cmt, "机器人") >= 0)
      return true;
   return false;
  }

bool CommentIsAi(const string cmt)
  {
   return (StringFind(cmt, "AI下单") >= 0 || StringFind(cmt, "机器人") >= 0);
  }

bool CommentIsManual(const string cmt)
  {
   return (StringFind(cmt, "专家") >= 0 || StringFind(cmt, "人工") >= 0);
  }

void CloseAiBarPositions(const string reason);
int  CountAiSettlePositions();

// 本交易日开盘时间：用品种日线开盘。新日线一开，今日平仓从 0 重计
datetime TradingDayOpen()
  {
   datetime t = iTime(_Symbol, PERIOD_D1, 0);
   if(t > 0)
      return t;
   return TimeCurrent() - 86400;
  }

// 今日已平仓盈亏：只统计本根日线开盘之后的平仓
double DayClosedPnL(double &winSum, double &lossSum)
  {
   winSum = 0.0;
   lossSum = 0.0;
   datetime dayOpen = TradingDayOpen();

   datetime from = dayOpen - 60;
   if(!HistorySelect(from, TimeCurrent() + 60))
      return 0.0;

   double sum = 0.0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(!IsOurClosedDeal(d))
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      if(t < dayOpen)
         continue;

      double p = HistoryDealGetDouble(d, DEAL_PROFIT)
               + HistoryDealGetDouble(d, DEAL_SWAP)
               + HistoryDealGetDouble(d, DEAL_COMMISSION);
      sum += p;
      if(p >= 0.0)
         winSum += p;
      else
         lossSum += p;
     }
   return sum;
  }

double DayClosedPnL()
  {
   double w = 0.0, l = 0.0;
   return DayClosedPnL(w, l);
  }

void ResetDayBaseline()
  {
   g_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   datetime open = TradingDayOpen();
   g_session_day_key = (int)open;
   PrintFormat("交易日开盘重置 今日平仓清零 开盘=%s 净值=%.2f",
               TimeToString(open, TIME_DATE|TIME_MINUTES), g_day_start_equity);
  }

void UpdateDayClock()
  {
   int openKey = (int)TradingDayOpen();
   if(g_session_day_key != openKey)
      ResetDayBaseline();
  }

bool CanOpenNewOrders()
  {
   // 只拦住止损冷却。开仓时段只限制 AI 自动开仓，时段外仍可手开。
   if(g_sl_pause_until > 0 && TimeCurrent() < g_sl_pause_until)
      return false;
   return true;
  }

string CmdFileName()
  {
   string name = SharedEntryFile;
   StringTrimLeft(name);
   StringTrimRight(name);
   if(StringLen(name) <= 0)
      name = ENTRY_FILE_DEFAULT;
   return name;
  }

bool IsCmdMaster()
  {
   if(!UseSharedConfig)
      return true;
   return SharedConfigMaster;
  }

// 兼容旧名
bool IsEntryMaster() { return IsCmdMaster(); }

string CmdQueueFileName()
  {
   string base = CmdFileName();
   int dot = StringLen(base) - 1;
   while(dot >= 0 && StringGetCharacter(base, dot) != '.')
      dot--;
   if(dot > 0)
      return StringSubstr(base, 0, dot) + ".queue";
   return base + ".queue";
  }

// Cmd: OPEN_BUY OPEN_SELL CLOSE_BUY CLOSE_SELL CLOSE_FIRST_BUY CLOSE_FIRST_SELL CLOSE_ALL PAUSE RESUME
bool CmdSignalRead(long &id, string &cmd)
  {
   id = 0;
   cmd = "";
   string name = CmdFileName();
   if(!FileIsExist(name, FILE_COMMON))
      return false;
   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   string sideLegacy = "";
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) <= 0 || StringGetCharacter(line, 0) == '#')
         continue;
      int eq = StringFind(line, "=");
      if(eq <= 0)
         continue;
      string k = StringSubstr(line, 0, eq);
      string v = StringSubstr(line, eq + 1);
      StringTrimLeft(k); StringTrimRight(k);
      StringTrimLeft(v); StringTrimRight(v);
      if(k == "CmdId" || k == "EntryId")
         id = StringToInteger(v);
      else if(k == "Cmd")
        {
         cmd = v;
         StringToUpper(cmd);
        }
      else if(k == "Side")
         sideLegacy = v;
     }
   FileClose(h);
   // 兼容旧入场文件：只有 Side=BUY/SELL
   if(cmd == "" && sideLegacy != "")
     {
      StringToUpper(sideLegacy);
      if(sideLegacy == "BUY" || sideLegacy == "0" || sideLegacy == "LONG")
         cmd = "OPEN_BUY";
      else if(sideLegacy == "SELL" || sideLegacy == "1" || sideLegacy == "SHORT")
         cmd = "OPEN_SELL";
     }
   return (id > 0 && cmd != "");
  }

long CmdQueueMaxId()
  {
   string name = CmdQueueFileName();
   if(!FileIsExist(name, FILE_COMMON))
      return 0;
   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return 0;
   long maxId = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) <= 0 || StringGetCharacter(line, 0) == '#')
         continue;
      int bar = StringFind(line, "|");
      if(bar <= 0)
         continue;
      long id = StringToInteger(StringSubstr(line, 0, bar));
      if(id > maxId)
         maxId = id;
     }
   FileClose(h);
   return maxId;
  }

string CmdAppliedFileName()
  {
   return StringFormat("%s%s.dat", CMD_APPLIED_FILE_PREFIX,
                       IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
  }

long CmdAppliedLoad()
  {
   string name = CmdAppliedFileName();
   if(!FileIsExist(name, FILE_COMMON))
      return 0;
   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return 0;
   long id = 0;
   if(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      id = StringToInteger(line);
     }
   FileClose(h);
   return id;
  }

void CmdAppliedSave()
  {
   if(!UseSharedConfig)
      return;
   string name = CmdAppliedFileName();
   int h = FileOpen(name, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, IntegerToString(g_applied_cmd_id) + "\n");
   FileClose(h);
  }

// 跳过历史队列时，仍吃最后一次 PAUSE/RESUME，避免主号已恢复从号还停着
void CmdApplyLastPauseResumeFromQueue()
  {
   string name = CmdQueueFileName();
   if(!FileIsExist(name, FILE_COMMON))
      return;
   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   string lastCtrl = "";
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) <= 0 || StringGetCharacter(line, 0) == '#')
         continue;
      int bar = StringFind(line, "|");
      if(bar <= 0)
         continue;
      string c = StringSubstr(line, bar + 1);
      StringTrimLeft(c);
      StringTrimRight(c);
      StringToUpper(c);
      if(c == "PAUSE" || c == "RESUME")
         lastCtrl = c;
     }
   FileClose(h);
   if(lastCtrl == "PAUSE")
     {
      g_pause_buy = true;
      g_pause_sell = true;
     }
   else if(lastCtrl == "RESUME")
     {
      g_pause_buy = false;
      g_pause_sell = false;
     }
  }

// 对齐指令水位：防 Wine/Common 晚就绪时 applied=0 把历史 OPEN 全重放
void CmdFollowAlignWatermark(const bool fromInit)
  {
   long qmax = CmdQueueMaxId();
   long cid = 0;
   string ccmd = "";
   if(CmdSignalRead(cid, ccmd) && cid > qmax)
      qmax = cid;

   long saved = CmdAppliedLoad();
   long mark = g_applied_cmd_id;
   if(saved > mark)
      mark = saved;
   if(qmax > mark)
      mark = qmax;

   // 初始化或 applied 仍为 0：必须跳到队尾，绝不能重放历史开仓
   if(fromInit || g_applied_cmd_id <= 0)
     {
      if(mark > g_applied_cmd_id)
        {
         PrintFormat("指令水位对齐：%s → %s（跳过历史，防连开）",
                     IntegerToString(g_applied_cmd_id), IntegerToString(mark));
         g_applied_cmd_id = mark;
         CmdAppliedSave();
         // 跳过的历史里可能有 RESUME：补齐暂停位
         CmdApplyLastPauseResumeFromQueue();
        }
      g_cmd_watermark_ready = (qmax > 0 || !FileIsExist(CmdQueueFileName(), FILE_COMMON));
      // 队列文件暂时打不开时，下一 tick 再对齐
      if(qmax <= 0 && FileIsExist(CmdQueueFileName(), FILE_COMMON))
         g_cmd_watermark_ready = false;
      return;
     }

   if(qmax > 0)
      g_cmd_watermark_ready = true;
  }

// 用持仓开仓时间恢复冷却，避免重挂EA后 lastAdd=0 导致无冷却连加
void SyncLastAddFromPositions()
  {
   datetime buyT = 0;
   datetime sellT = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicBase)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         if(t > buyT)
            buyT = t;
        }
      else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
         if(t > sellT)
            sellT = t;
        }
     }
   if(buyT > g_lastAddBuy)
      g_lastAddBuy = buyT;
   if(sellT > g_lastAddSell)
      g_lastAddSell = sellT;
  }

// 读取 afterId 之后的指令（按 id 升序），最多 maxN 条
int CmdQueueReadPending(const long afterId, long &ids[], string &cmds[], const int maxN)
  {
   ArrayResize(ids, 0);
   ArrayResize(cmds, 0);
   string name = CmdQueueFileName();
   if(!FileIsExist(name, FILE_COMMON) || maxN <= 0)
      return 0;
   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return 0;
   long rawId[];
   string rawCmd[];
   int n = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) <= 0 || StringGetCharacter(line, 0) == '#')
         continue;
      int bar = StringFind(line, "|");
      if(bar <= 0)
         continue;
      long id = StringToInteger(StringSubstr(line, 0, bar));
      string c = StringSubstr(line, bar + 1);
      StringTrimLeft(c);
      StringTrimRight(c);
      StringToUpper(c);
      if(id <= afterId || c == "")
         continue;
      ArrayResize(rawId, n + 1);
      ArrayResize(rawCmd, n + 1);
      rawId[n] = id;
      rawCmd[n] = c;
      n++;
     }
   FileClose(h);
   // 升序
   for(int a = 0; a < n - 1; a++)
     {
      for(int b = 0; b < n - 1 - a; b++)
        {
         if(rawId[b] > rawId[b + 1])
           {
            long td = rawId[b]; rawId[b] = rawId[b + 1]; rawId[b + 1] = td;
            string tc = rawCmd[b]; rawCmd[b] = rawCmd[b + 1]; rawCmd[b + 1] = tc;
           }
        }
     }
   int outN = n;
   if(outN > maxN)
      outN = maxN;
   ArrayResize(ids, outN);
   ArrayResize(cmds, outN);
   for(int k = 0; k < outN; k++)
     {
      ids[k] = rawId[k];
      cmds[k] = rawCmd[k];
     }
   return outN;
  }

void CmdQueueTrimIfNeeded()
  {
   string name = CmdQueueFileName();
   if(!FileIsExist(name, FILE_COMMON))
      return;
   int h = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   string lines[];
   int n = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimRight(line);
      if(StringLen(line) <= 0)
         continue;
      ArrayResize(lines, n + 1);
      lines[n++] = line;
     }
   FileClose(h);
   if(n <= CMD_QUEUE_KEEP_LINES)
      return;
   int start = n - CMD_QUEUE_KEEP_LINES;
   h = FileOpen(name, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, "# command queue (id|CMD)\n");
   for(int i = start; i < n; i++)
      FileWriteString(h, lines[i] + "\n");
   FileClose(h);
  }

bool CmdQueueAppend(const long id, const string cmd)
  {
   string c = cmd;
   StringToUpper(c);
   string name = CmdQueueFileName();
   // 若队尾已是同一 id+指令，不再追加（防止双写）
   if(FileIsExist(name, FILE_COMMON))
     {
      int hr = FileOpen(name, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(hr != INVALID_HANDLE)
        {
         string lastLine = "";
         while(!FileIsEnding(hr))
           {
            string line = FileReadString(hr);
            StringTrimRight(line);
            if(StringLen(line) > 0)
               lastLine = line;
           }
         FileClose(hr);
         string expect = StringFormat("%s|%s", IntegerToString(id), c);
         if(lastLine == expect)
           {
            PrintFormat("队列末尾已是 %s，跳过重复追加", expect);
            return true;
           }
        }
     }
   int h = FileOpen(name, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
      h = FileOpen(name, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("指令队列写入失败: %s err=%d", name, GetLastError());
      return false;
     }
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, StringFormat("%s|%s\n", IntegerToString(id), c));
   FileClose(h);
   CmdQueueTrimIfNeeded();
   return true;
  }

bool CmdSignalWrite(const long id, const string cmd)
  {
   string c = cmd;
   StringToUpper(c);
   // 先追加队列，保证连点平#1 从号也能按序跟上
   if(!CmdQueueAppend(id, c))
      return false;
   string name = CmdFileName();
   int h = FileOpen(name, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("指令写入失败: %s err=%d", name, GetLastError());
      return false;
     }
   FileWriteString(h, "# master command broadcast\n");
   FileWriteString(h, StringFormat("CmdId=%s\n", IntegerToString(id)));
   FileWriteString(h, StringFormat("Cmd=%s\n", c));
   // 兼容旧从号：开仓指令仍写 Side
   if(c == "OPEN_BUY" || c == "AI_BUY")
      FileWriteString(h, "Side=BUY\n");
   else if(c == "OPEN_SELL" || c == "AI_SELL")
      FileWriteString(h, "Side=SELL\n");
   FileWriteString(h, StringFormat("CmdTime=%s\n", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)));
   FileWriteString(h, StringFormat("MasterLogin=%s\n", IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))));
   FileClose(h);
   return true;
  }

bool ExecuteManualOpenSide(const int side, const string reason, const bool followMaster = false, const string who = "专家")
  {
   if(side != 0 && side != 1)
      return false;
   string hand = (StringFind(who, "专家") >= 0 || StringFind(who, "人工") >= 0) ? "手动" : "自动";
   if(BotFullyPaused())
     {
      g_last_open_fail = "已暂停";
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }
   if(g_InitLot <= 0.0)
     {
      g_last_open_fail = "起手手数是0";
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }
   if(g_MaxLayers <= 0)
     {
      g_last_open_fail = "封顶层数是0";
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }
   if(!CanOpenNewOrders())
     {
      g_last_open_fail = "止损冷却中";
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }

   // 时段内维持一单一结。时段结束后，面板手开不再被这根 K 线挡住。
   if(AiDrivesEntry() && InOpenSession() && CountPositions() > 0)
     {
      g_last_open_fail = "已有持仓，一单一结不再开";
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }

   const int posType = (side == 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
   const ENUM_ORDER_TYPE orderType = (side == 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   int layers = CountPositions(posType, true);
   if(layers >= g_MaxLayers)
     {
      g_last_open_fail = StringFormat("%s已达封顶 %d 层", (side == 0 ? "多" : "空"), g_MaxLayers);
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }
   if(posType == POSITION_TYPE_BUY && g_pause_buy)
     {
      g_last_open_fail = "多单这边已暂停";
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }
   if(posType == POSITION_TYPE_SELL && g_pause_sell)
     {
      g_last_open_fail = "空单这边已暂停";
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }

   // 主号：完整冷却。从号跟随：仍强制最短间隔，防队列连发导致 1 秒两单
   datetime lastAdd = LastAddTimeOf(posType);
   int coolNeed = g_AddCooldownSec;
   if(followMaster)
      coolNeed = MathMax(2, g_AddCooldownSec / 3); // 至少 2 秒，避免同价连开
   if(coolNeed > 0 && lastAdd > 0 && TimeCurrent() - lastAdd < coolNeed)
     {
      g_last_open_fail = StringFormat("冷却中，还要等%d秒", coolNeed - (int)(TimeCurrent() - lastAdd));
      PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
      return false;
     }

   // 加仓间距校验：默认关闭，方便手补；自动马丁仍走 ManageMartinSide 自己的间距
   if(ManualOpenNeedSpacing && layers > 0)
     {
      bool foundPx = false;
      double lastPx = LastOpenPrice(posType, foundPx, true);
      double step = CurrentGridStepUSD(layers);
      if(foundPx && step > 0.0)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double dist = (posType == POSITION_TYPE_BUY ? (lastPx - bid) : (ask - lastPx));
         // 允许 0.5 倍间距容差（滑点）；不足则拒开
         if(dist < step * 0.5)
           {
            g_last_open_fail = StringFormat("间距不足，现在距%.2f，需要≥%.2f", dist, step * 0.5);
            PrintFormat("%s开仓失败: %s | %s", hand, g_last_open_fail, reason);
            return false;
           }
        }
     }

   double lot = (layers <= 0) ? NormalizeLot(g_InitLot) : NextMartinLot(posType);
   string tag = who + (side == 0 ? "多" : "空");
   g_last_open_fail = "";
   bool ok = OpenMarket(orderType, lot, tag);
   PrintFormat("%s → %s第%d层 手=%.2f 结果=%s%s",
               reason, (side == 0 ? "多" : "空"), layers + 1, lot,
               (ok ? "成功" : "失败"),
               (ok || g_last_open_fail == "" ? "" : ("，原因: " + g_last_open_fail)));
   return ok;
  }

bool ExecuteSharedCmd(const string cmd, const string reason, const bool followMaster = false)
  {
   string c = cmd;
   StringToUpper(c);
   if(c == "OPEN_BUY" || c == "AI_BUY")
      return ExecuteManualOpenSide(0, reason, followMaster, (c == "AI_BUY" ? "AI下单" : "专家"));
   if(c == "OPEN_SELL" || c == "AI_SELL")
      return ExecuteManualOpenSide(1, reason, followMaster, (c == "AI_SELL" ? "AI下单" : "专家"));
   if(c == "CLOSE_BUY")
     {
      CloseOurPositionsByType(POSITION_TYPE_BUY, reason + "：平多");
      return true;
     }
   if(c == "CLOSE_SELL")
     {
      CloseOurPositionsByType(POSITION_TYPE_SELL, reason + "：平空");
      return true;
     }
   if(c == "CLOSE_FIRST_BUY")
      return CloseFirstOfSide(POSITION_TYPE_BUY, reason + "：平多#1");
   if(c == "CLOSE_FIRST_SELL")
      return CloseFirstOfSide(POSITION_TYPE_SELL, reason + "：平空#1");
   if(c == "CLOSE_ALL")
     {
      CloseAllOurPositions(reason + "：全部平仓");
      return true;
     }
   if(c == "CLOSE_AI")
     {
      CloseAiBarPositions(reason + "：AI这根K线平仓");
      return true;
     }
   if(c == "PAUSE")
     {
      g_pause_buy = true;
      g_pause_sell = true;
      Print(reason, "：已暂停");
      return true;
     }
   if(c == "RESUME")
     {
      g_pause_buy = false;
      g_pause_sell = false;
      Print(reason, "：已恢复");
      return true;
     }
   Print("未知指令: ", c);
   return false;
  }

bool IsOpenSharedCmd(const string cmd)
  {
   string c = cmd;
   StringToUpper(c);
   return (c == "OPEN_BUY" || c == "OPEN_SELL" || c == "AI_BUY" || c == "AI_SELL");
  }

void ProcessCmdSignalFollow()
  {
   if(IsCmdMaster())
      return;

   // Common 晚就绪时补齐水位，禁止 applied=0 重放整段历史开仓
   if(!g_cmd_watermark_ready || g_applied_cmd_id <= 0)
      CmdFollowAlignWatermark(false);

   // 优先走队列：主号连点平#1 时从号按序补齐，不会只跟最后一笔
   long ids[];
   string cmds[];
   int n = CmdQueueReadPending(g_applied_cmd_id, ids, cmds, CMD_QUEUE_MAX_PENDING);
   if(n > 0)
     {
      int opensThisTick = 0;
      for(int i = 0; i < n; i++)
        {
         if(ids[i] <= g_applied_cmd_id)
            continue;
         // 每 tick 最多跟 1 笔开仓，平仓/暂停仍可继续处理
         if(IsOpenSharedCmd(cmds[i]) && opensThisTick >= CMD_FOLLOW_MAX_OPEN_PER_TICK)
            break;

         string reason = "跟随主号#" + IntegerToString(ids[i]);
         if(!ExecuteSharedCmd(cmds[i], reason, true))
           {
            // 关键：暂停中开仓失败若 break，会永远堵死后面的 RESUME
            if(IsOpenSharedCmd(cmds[i]) && BotFullyPaused())
              {
               PrintFormat("%s：暂停中跳过开仓，继续处理后续恢复/平仓", reason);
               g_applied_cmd_id = ids[i];
               CmdAppliedSave();
               continue;
              }
            // 封顶/间距不足：永久跳过，避免堵队列或同价连开
            if(IsOpenSharedCmd(cmds[i]))
              {
               string oc = cmds[i];
               StringToUpper(oc);
               int pt = (oc == "OPEN_BUY" ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
               if(CountPositions(pt, true) >= g_MaxLayers)
                 {
                  PrintFormat("%s：已封顶跳过开仓", reason);
                  g_applied_cmd_id = ids[i];
                  CmdAppliedSave();
                  continue;
                 }
               // 仅当开启「手开也要间距」时，间距不足才永久跳过
               if(ManualOpenNeedSpacing)
                 {
                  bool fp = false;
                  double lpx = LastOpenPrice(pt, fp, true);
                  double stp = CurrentGridStepUSD(MathMax(1, CountPositions(pt, true)));
                  if(fp && stp > 0.0)
                    {
                     double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                     double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                     double dist = (pt == POSITION_TYPE_BUY ? (lpx - bid) : (ask - lpx));
                     if(dist < stp * 0.5)
                       {
                        PrintFormat("%s：间距不足跳过，防连单", reason);
                        g_applied_cmd_id = ids[i];
                        CmdAppliedSave();
                        continue;
                       }
                    }
                 }
               // 点差等瞬时失败：先偷看后面的暂停/恢复并生效（不跳过本笔开仓）
               for(int j = i + 1; j < n; j++)
                 {
                  string cj = cmds[j];
                  StringToUpper(cj);
                  if(cj != "PAUSE" && cj != "RESUME")
                     continue;
                  ExecuteSharedCmd(cmds[j], "抢先同步#" + IntegerToString(ids[j]), true);
                  RefreshPanelButtons();
                 }
              }
            // 其它失败（点差等）下个 tick 重试本笔开仓
            break;
           }
         g_applied_cmd_id = ids[i];
         CmdAppliedSave();
         if(IsOpenSharedCmd(cmds[i]))
            opensThisTick++;
        }
      RefreshPanelButtons();
      return;
     }
   // 兼容无队列的旧 .sig
   long id = 0;
   string cmd = "";
   if(!CmdSignalRead(id, cmd))
      return;
   if(id <= g_applied_cmd_id)
      return;
   if(!ExecuteSharedCmd(cmd, "跟随主号#" + IntegerToString(id), true))
     {
      if(IsOpenSharedCmd(cmd) && BotFullyPaused())
        {
         PrintFormat("跟随主号#%d：暂停中跳过开仓", id);
         g_applied_cmd_id = id;
         CmdAppliedSave();
         RefreshPanelButtons();
        }
      return;
     }
   g_applied_cmd_id = id;
   CmdAppliedSave();
   RefreshPanelButtons();
  }

// 兼容旧调用名
void ProcessEntrySignalFollow() { ProcessCmdSignalFollow(); }

bool MasterBroadcastCmd(const string cmd)
  {
   if(!IsCmdMaster())
     {
      Print("从号不能发令，请在主号操作面板");
      return false;
     }
   string c = cmd;
   StringToUpper(c);
   // 暂停时禁止把开仓写入队列，否则从号暂停中执行失败会堵 RESUME
   if(IsOpenSharedCmd(c) && BotFullyPaused())
     {
      Print("已暂停，不发开仓指令");
      return false;
     }
   // 单调递增，禁止用 TimeCurrent 当 Id（同秒连发会撞号，从号一批执行两次）
   long id = g_applied_cmd_id + 1;
   long qmax = CmdQueueMaxId();
   if(id <= qmax)
      id = qmax + 1;

   // 开仓：必须本机先成交成功，才写入队列（避免主号失败从号却多开）
   if(IsOpenSharedCmd(c))
     {
      if(!ExecuteSharedCmd(c, "主号#" + IntegerToString(id)))
        {
         PrintFormat("主号开仓失败，不广播 #%s %s", IntegerToString(id), c);
         return false;
        }
      if(!CmdSignalWrite(id, c))
        {
         Print("主号已开仓但队列写入失败，从号可能少跟一单");
         g_applied_cmd_id = id;
         CmdAppliedSave();
         RefreshPanelButtons();
         return true;
        }
     }
   else
     {
      // 平仓/暂停：先写入再执行，保证从号能跟上
      if(!CmdSignalWrite(id, c))
         return false;
      ExecuteSharedCmd(c, "主号#" + IntegerToString(id));
     }

   g_applied_cmd_id = id;
   CmdAppliedSave();
   if(UseSharedConfig && SharedConfigMaster)
      CfgWriteShared();
   RefreshPanelButtons();
   return true;
  }

void MasterTriggerEntrySide(const int side)
  {
   MasterBroadcastCmd(side == 0 ? "OPEN_BUY" : "OPEN_SELL");
  }

void TrackSpread2H()
  {
   long spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   datetime now = TimeCurrent();
   if(g_spread_window_start <= 0 || now - g_spread_window_start >= 7200)
     {
      g_spread_window_start = now;
      g_spread_max_2h_pts = spr;
     }
   else if(spr > g_spread_max_2h_pts)
      g_spread_max_2h_pts = spr;
  }

#ifdef EA_BUILD_WITH_AI
double CalcRange2HUSD()
  {
   datetime t0 = TimeCurrent() - 7200;
   int shift = iBarShift(_Symbol, AiJudgeTF, t0, false);
   if(shift < 1)
      shift = 24;
   double hi = -1.0, lo = 1.0e100;
   int n = MathMin(shift + 1, 120);
   for(int i = 0; i < n; i++)
     {
      double h = iHigh(_Symbol, AiJudgeTF, i);
      double l = iLow(_Symbol, AiJudgeTF, i);
      if(h > hi) hi = h;
      if(l < lo && l > 0.0) lo = l;
     }
   if(hi < 0.0 || lo >= 1.0e99)
      return 0.0;
   return hi - lo;
  }

void AiPanelClearLines()
  {
   g_ai_panel_n = 0;
   for(int i = 0; i < AI_PANEL_LINE_MAX; i++)
      g_ai_panel_lines[i] = "";
  }

void AiPanelAddLine(const string s)
  {
   if(g_ai_panel_n >= AI_PANEL_LINE_MAX)
      return;
   g_ai_panel_lines[g_ai_panel_n] = s;
   g_ai_panel_n++;
  }

// 按字数折行（窄面板一行约 26 字，最多 2 行）
void AiPanelAddWrapped(const string prefix, const string body, const int width)
  {
   string rest = body;
   StringTrimLeft(rest);
   StringTrimRight(rest);
   if(rest == "")
     {
      AiPanelAddLine(prefix + "-");
      return;
     }
   const int w = MathMax(16, width);
   bool first = true;
   while(StringLen(rest) > 0 && g_ai_panel_n < AI_PANEL_LINE_MAX)
     {
      string head = (first ? prefix : "　　");
      int room = w - StringLen(head);
      if(room < 8)
         room = 8;
      if(StringLen(rest) <= room)
        {
         AiPanelAddLine(head + rest);
         break;
        }
      AiPanelAddLine(head + StringSubstr(rest, 0, room));
      rest = StringSubstr(rest, room);
      first = false;
     }
  }

int AiPanelExtraRows()
  {
   if(!UseExternalAI)
      return 0;
   return 2;
  }

double PanelRsiValue()
  {
   int h = g_chart_rsi;
#ifdef EA_BUILD_WITH_AI
   if(h == INVALID_HANDLE)
      h = g_ai_rsi_handle;
#endif
   if(h == INVALID_HANDLE)
      return g_panel_rsi;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h, 0, 0, 1, buf) < 1 || buf[0] <= 0.0)
      return g_panel_rsi;
   g_panel_rsi = buf[0];
   return g_panel_rsi;
  }

color PanelRsiColor()
  {
   if(g_panel_rsi >= 70.0)
      return UI_COL_RED;
   if(g_panel_rsi > 0.0 && g_panel_rsi <= 30.0)
      return UI_COL_GREEN;
   return UI_COL_TITLE;
  }

string PanelLevelText(const string name, const double px)
  {
   if(px <= 0.0)
      return name + " -";
   return name + " " + DoubleToString(px, _Digits);
  }

void AiClearLevelObjectsSafe()
  {
   AutoJudge_ClearLevelObjects();
  }

void AiReleaseIndicators()
  {
   if(g_ai_adx_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_ai_adx_handle);
      g_ai_adx_handle = INVALID_HANDLE;
     }
   if(g_ai_rsi_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_ai_rsi_handle);
      g_ai_rsi_handle = INVALID_HANDLE;
     }
   if(g_ai_ema5_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_ai_ema5_handle);
      g_ai_ema5_handle = INVALID_HANDLE;
     }
   if(g_ai_ema10_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_ai_ema10_handle);
      g_ai_ema10_handle = INVALID_HANDLE;
     }
   if(g_ai_ema20_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_ai_ema20_handle);
      g_ai_ema20_handle = INVALID_HANDLE;
     }
  }

void AiOnInitReset()
  {
   g_ai_last_snapshot = 0;
   g_ai_last_load = 0;
   AutoJudge_Clear(g_ai_judge);
   AiPanelClearLines();
   AiReleaseIndicators();
   g_ai_adx_handle = iADX(_Symbol, PERIOD_M5, 14);
   g_ai_rsi_handle = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   RefreshEmaHandles();
  }

void RefreshEmaHandles()
  {
   if(g_ai_ema5_handle != INVALID_HANDLE)  IndicatorRelease(g_ai_ema5_handle);
   if(g_ai_ema10_handle != INVALID_HANDLE) IndicatorRelease(g_ai_ema10_handle);
   if(g_ai_ema20_handle != INVALID_HANDLE) IndicatorRelease(g_ai_ema20_handle);
   g_ai_ema5_handle  = iMA(_Symbol, PERIOD_M5, 5, 0, MODE_EMA, PRICE_CLOSE);
   g_ai_ema10_handle = iMA(_Symbol, PERIOD_M5, 10, 0, MODE_EMA, PRICE_CLOSE);
   g_ai_ema20_handle = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
  }

double AiReadIndicatorShift(const int handle, const int buffer, const int shift)
  {
   if(handle == INVALID_HANDLE)
      return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, buffer, shift, 1, buf) < 1)
      return 0.0;
   return buf[0];
  }

double AiReadIndicator(const int handle, const int buffer)
  {
   return AiReadIndicatorShift(handle, buffer, 0);
  }

// 这一次 DeepSeek 原文的方向。1 多，-1 空，0 先别做。
int DeepSeekRawSide()
  {
   if(g_ai_judge.freeze_orders)
      return 0;
   if(g_ai_judge.direction == TREND_UP || g_ai_judge.direction == TREND_LEAN_UP)
      return 1;
   if(g_ai_judge.direction == TREND_DOWN || g_ai_judge.direction == TREND_LEAN_DOWN)
      return -1;
   return 0;
  }

// 信心达到 72 才算趋势。不到 72，或方向是中性，都当震荡。
bool DeepSeekTrend()
  {
   if(g_ai_judge.freeze_orders)
      return false;
   if(g_ai_judge.confidence < 72.0)
      return false;
   return (DeepSeekRawSide() != 0);
  }

// 前三根已收盘 M5 的均价：(高+低+收)/3 再平均。
double M5Mean3()
  {
   double sum = 0.0;
   int n = 0;
   for(int i = 1; i <= 3; i++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      double c = iClose(_Symbol, PERIOD_M5, i);
      if(h <= 0.0 || l <= 0.0 || c <= 0.0)
         continue;
      sum += (h + l + c) / 3.0;
      n++;
     }
   if(n < 3)
      return 0.0;
   return sum / 3.0;
  }

double RsiAt(const int shift)
  {
   int h = g_chart_rsi;
   if(h == INVALID_HANDLE)
      h = g_ai_rsi_handle;
   return AiReadIndicatorShift(h, 0, shift);
  }

// 面板上的 RSI。上一根到 55 以上再往下拐，算上涨没力。上一根到 45 以下再往上拐，算下跌没力。
int RsiExhaust()
  {
   double now = RsiAt(0);
   double prev = RsiAt(1);
   if(now <= 0.0 || prev <= 0.0)
      return 0;
   if(prev >= 55.0 && now < prev)
      return -1;
   if(prev <= 45.0 && now > prev)
      return 1;
   return 0;
  }

// 最近这串 5 分钟还在单边就返回 1 或 -1。追完、开始来回则返回 0。
int M5Leg()
  {
   double nh = 0.0, oh = 0.0, nl = 1.0e100, ol = 1.0e100;
   for(int i = 1; i <= 4; i++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(h > nh) nh = h;
      if(l > 0.0 && l < nl) nl = l;
     }
   for(int i = 5; i <= 8; i++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(h > oh) oh = h;
      if(l > 0.0 && l < ol) ol = l;
     }
   if(nh <= 0.0 || oh <= 0.0 || nl > 1.0e99 || ol > 1.0e99)
      return 0;
   if(nh > oh && nl > ol)
      return 1;
   if(nh < oh && nl < ol)
      return -1;
   // 连续三根收盘同向，并且比第四根至少走出 2 美元。这种还在追，不算震荡。
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);
   double c3 = iClose(_Symbol, PERIOD_M5, 3);
   double c4 = iClose(_Symbol, PERIOD_M5, 4);
   if(c1 > c2 && c2 > c3 && c1 - c4 >= 2.0)
      return 1;
   if(c1 < c2 && c2 < c3 && c4 - c1 >= 2.0)
      return -1;
   // 连涨刚结束的回落，趋势还在，不能当成震荡。
   if(c2 > c3 && c3 > c4 && c1 < c2 && c1 > c4)
      return 1;
   if(c2 < c3 && c3 < c4 && c1 > c2 && c1 < c4)
      return -1;
   return 0;
  }

// 长线先观望：正在走的或刚收盘的这根振幅明显偏大，或近 5 根已经走出一段且收盘还在尽头。
bool LongLineWatch()
  {
   double sum = 0.0;
   int n = 0;
   for(int i = 1; i <= 8; i++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(h <= l || l <= 0.0)
         continue;
      sum += (h - l);
      n++;
     }
   double avg = (n > 0 ? sum / n : 0.0);
   for(int shift = 0; shift <= 1; shift++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, shift);
      double l = iLow(_Symbol, PERIOD_M5, shift);
      double r = h - l;
      if(r >= 8.0)
         return true;
      if(r >= 6.0 && avg > 0.0 && r >= avg * 1.8)
         return true;
     }
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double c5 = iClose(_Symbol, PERIOD_M5, 5);
   if(c1 <= 0.0 || c5 <= 0.0)
      return false;
   double hi = c1;
   double lo = c1;
   for(int i = 1; i <= 5; i++)
     {
      double c = iClose(_Symbol, PERIOD_M5, i);
      if(c <= 0.0)
         continue;
      if(c > hi) hi = c;
      if(c < lo) lo = c;
     }
   if(MathAbs(c1 - c5) >= 8.0 && (c1 >= hi - 0.01 || c1 <= lo + 0.01))
      return true;
   return false;
  }

// 大起大落前的 5 根收盘 K 线差不多高、差不多低。正在走的这根打破那一簇，就是进场。
int SimilarBaseBreak()
  {
   double maxH = 0.0, minL = 1.0e100;
   double maxHi = 0.0, minHi = 1.0e100, maxLo = 0.0, minLo = 1.0e100;
   double sumR = 0.0;
   int n = 0;
   for(int i = 1; i <= 5; i++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(h <= l || l <= 0.0)
         return 0;
      if(h > maxH) maxH = h;
      if(l < minL) minL = l;
      if(h > maxHi) maxHi = h;
      if(h < minHi) minHi = h;
      if(l > maxLo) maxLo = l;
      if(l < minLo) minLo = l;
      sumR += (h - l);
      n++;
     }
   if(n < 5)
      return 0;
   double avgR = sumR / n;
   if(avgR <= 0.0)
      return 0;
   if((maxHi - minHi) > avgR * 1.3 || (maxLo - minLo) > avgR * 1.3)
      return 0;
   if((maxH - minL) > avgR * 2.2)
      return 0;
   double h0 = iHigh(_Symbol, PERIOD_M5, 0);
   double l0 = iLow(_Symbol, PERIOD_M5, 0);
   double r0 = h0 - l0;
   if(r0 < avgR * 1.6 && r0 < 4.0)
      return 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(l0 <= minL && bid <= minL - 0.5)
      return -1;
   if(h0 >= maxH && ask >= maxH + 0.5)
      return 1;
   return 0;
  }

// 趋势做多不买最高收盘：前一根还在涨，最近一根收盘回落，但仍高于起涨那根。
bool TrendDipReady(const int side)
  {
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);
   double c3 = iClose(_Symbol, PERIOD_M5, 3);
   double c4 = iClose(_Symbol, PERIOD_M5, 4);
   if(c1 <= 0.0 || c2 <= 0.0 || c4 <= 0.0)
      return false;
   if(side > 0)
      return (c2 >= c3 && c1 < c2 && c1 > c4);
   if(side < 0)
      return (c2 <= c3 && c1 > c2 && c1 < c4);
   return false;
  }

// 震荡区间的最高、最低取最近 10 根已收盘 5 分钟。1 点按 1 美元。
bool MeasureRangeBox()
  {
   g_chop_hi = 0.0;
   g_chop_lo = 1.0e100;
   g_chop_pts = 0.0;
   for(int i = 1; i <= 10; i++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(h > g_chop_hi) g_chop_hi = h;
      if(l > 0.0 && l < g_chop_lo) g_chop_lo = l;
     }
   if(g_chop_hi <= 0.0 || g_chop_lo > 1.0e99 || g_chop_hi <= g_chop_lo)
      return false;
   g_chop_pts = g_chop_hi - g_chop_lo;
   if(g_chop_pts < 4.0 || g_chop_pts > 30.0)
      return false;
   return true;
  }

// 趋势追完后的箱子。点数=最高减最低，1 点按 1 美元。
bool MeasureChopBox(const bool allowWhileLeg = false)
  {
   g_chop_hi = 0.0;
   g_chop_lo = 1.0e100;
   g_chop_pts = 0.0;
   if(!allowWhileLeg && M5Leg() != 0)
      return false;
   for(int i = 1; i <= 12; i++)
     {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(h > g_chop_hi) g_chop_hi = h;
      if(l > 0.0 && l < g_chop_lo) g_chop_lo = l;
     }
   if(g_chop_hi <= 0.0 || g_chop_lo > 1.0e99)
      return false;
   g_chop_pts = g_chop_hi - g_chop_lo;
   if(g_chop_pts < 4.0 || g_chop_pts > 30.0)
      return false;
   return true;
  }

// 震荡要三件一起对上：最近10根5分钟的上沿或下沿、均价一侧、RSI无力。不看30分钟方向。
int ChopSide()
  {
   if(!MeasureRangeBox())
      return 0;
   double avg = M5Mean3();
   if(avg <= 0.0 || g_chop_pts <= 0.0)
      return 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pos = (bid - g_chop_lo) / g_chop_pts;
   int rsiTurn = RsiExhaust();
   if(pos >= 0.75 && bid > avg && rsiTurn < 0)
      return -1;
   if(pos <= 0.25 && ask < avg && rsiTurn > 0)
      return 1;
   return 0;
  }

// 均价上面只等上涨无力做空。均价下面只等下跌无力做多。均价上方不做多。
int MeanExhaustSide()
  {
   double avg = M5Mean3();
   if(avg <= 0.0)
      return 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int rsiTurn = RsiExhaust();
   if(bid > avg && rsiTurn < 0)
      return -1;
   if(ask < avg && rsiTurn > 0)
      return 1;
   return 0;
  }

// 最近一根已收盘 5 分钟。1=下针，-1=上针，2=纺锤，0=普通。方向仍以 30 分钟为准。
int M5PinSide()
  {
   double o = iOpen(_Symbol, PERIOD_M5, 1);
   double h = iHigh(_Symbol, PERIOD_M5, 1);
   double l = iLow(_Symbol, PERIOD_M5, 1);
   double c = iClose(_Symbol, PERIOD_M5, 1);
   double range = h - l;
   if(o <= 0.0 || range <= 0.0)
      return 0;
   double body = MathAbs(c - o);
   double upper = h - MathMax(o, c);
   double lower = MathMin(o, c) - l;
   if(body <= range * 0.30 && upper >= range * 0.25 && lower >= range * 0.25)
      return 2;
   if(lower >= body * 2.0 && lower >= range * 0.60 && upper <= range * 0.25)
      return 1;
   if(upper >= body * 2.0 && upper >= range * 0.60 && lower <= range * 0.25)
      return -1;
   return 0;
  }

bool TouchedSupportRecently()
  {
   double sup = g_ai_judge.support1;
   if(sup <= 0.0)
      return false;
   double px = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   if(px <= sup + 2.0)
      return true;
   for(int i = 1; i <= 4; i++)
     {
      if(iLow(_Symbol, PERIOD_M5, i) <= sup + 2.0)
         return true;
     }
   return false;
  }

bool TouchedResistRecently()
  {
   double res = g_ai_judge.resist1;
   if(res <= 0.0)
      return false;
   double px = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   if(px >= res - 2.0)
      return true;
   for(int i = 1; i <= 4; i++)
     {
      if(iHigh(_Symbol, PERIOD_M5, i) >= res - 2.0)
         return true;
     }
   return false;
  }

// 还贴着支撑，或回调还在往上走：先看，这根不空。回调收盘掉下来并且已经离开支撑，才可以空。
bool WaitBounceShort()
  {
   double sup = g_ai_judge.support1;
   if(sup <= 0.0 || !TouchedSupportRecently())
      return false;
   double px = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   if(px <= sup + 2.0)
      return true;
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);
   if(c1 <= 0.0 || c2 <= 0.0 || c1 > c2)
      return true;
   return false;
  }

// 还贴着压力，或回调还在往下走：先看，这根不多。回调收盘抬起来并且已经离开压力，才可以多。
bool WaitBounceLong()
  {
   double res = g_ai_judge.resist1;
   if(res <= 0.0 || !TouchedResistRecently())
      return false;
   double px = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   if(px >= res - 2.0)
      return true;
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);
   if(c1 <= 0.0 || c2 <= 0.0 || c1 < c2)
      return true;
   return false;
  }

bool NearSupport()
  {
   return WaitBounceShort();
  }

bool NearResist()
  {
   return WaitBounceLong();
  }

bool PriceAboveMean()
  {
   double avg = M5Mean3();
   if(avg <= 0.0)
      return false;
   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   return (mid > avg);
  }

// 趋势方向只认信心达到 72 的 DeepSeek。第一次给出的方向先站住。
// 要换成另一边，必须连续两份新结果都是同一边，否则保持原方向。
int DeepSeekOpenSide()
  {
   if(!AiBridgeOn() || !g_ai_judge.from_external_ai)
      return 0;
   string teach = "ai\\teach.txt";
   if(!FileIsExist(teach, FILE_COMMON))
      return 0;
   datetime mt = (datetime)FileGetInteger(teach, FILE_MODIFY_DATE, FILE_COMMON);
   if(mt <= 0 || TimeCurrent() - mt > 90)
      return 0;
   int raw = DeepSeekRawSide();
   if(mt != g_ai_seen_teach)
     {
      g_ai_seen_teach = mt;
      if(g_ai_hold_side == 0)
        {
         g_ai_hold_side = raw;
         g_ai_flip_side = 0;
         g_ai_flip_hits = 0;
        }
      else if(raw == g_ai_hold_side)
        {
         g_ai_flip_side = 0;
         g_ai_flip_hits = 0;
        }
      else if(raw == 0)
        {
         // 偶尔先别做，不把已经站住的方向清掉
         g_ai_flip_side = 0;
         g_ai_flip_hits = 0;
        }
      else if(raw == g_ai_flip_side)
        {
         g_ai_flip_hits++;
         if(g_ai_flip_hits >= 2)
           {
            g_ai_hold_side = raw;
            g_ai_flip_side = 0;
            g_ai_flip_hits = 0;
           }
        }
      else
        {
         g_ai_flip_side = raw;
         g_ai_flip_hits = 1;
        }
     }
   return g_ai_hold_side;
  }

// 复盘确认看错的那一边。五分钟结构重新回到这一边且信心到 72 才解除。
int MistakeSide()
  {
   string path = "ai\\mistake.txt";
   if(!FileIsExist(path, FILE_COMMON))
      return 0;
   datetime mt = (datetime)FileGetInteger(path, FILE_MODIFY_DATE, FILE_COMMON);
   if(mt > 0 && TimeCurrent() - mt > 6 * 3600)
     {
      FileDelete(path, FILE_COMMON);
      return 0;
     }
   int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_UNICODE|FILE_COMMON);
   if(h == INVALID_HANDLE)
      return 0;
   int side = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(StringFind(line, "BAD_DIR=UP") >= 0)
         side = 1;
      else if(StringFind(line, "BAD_DIR=DOWN") >= 0)
         side = -1;
     }
   FileClose(h);
   return side;
  }

void ReleaseMistakeIfFixed()
  {
   int bad = MistakeSide();
   if(bad == 0 || g_ai_judge.confidence < 72.0)
      return;
   if(M5Leg() != bad || DeepSeekOpenSide() != bad)
      return;
   FileDelete("ai\\mistake.txt", FILE_COMMON);
   Print(bad > 0 ? "五分钟重新抬高，解除不做多" : "五分钟重新走低，解除不做空");
  }

string DeepSeekJudgeLine()
  {
   double meanPx0 = M5Mean3();
   string meanHead = (meanPx0 > 0.0 ? "三根均价 " + DoubleToString(meanPx0, _Digits) + " | " : "");
   if(!AiBridgeOn() || !g_ai_judge.from_external_ai)
      return meanHead + "AI未开，不下单";
   string why = g_ai_judge.reason;
   if(StringLen(why) > 22)
      why = StringSubstr(why, 0, 22);
   string meanTxt = meanHead;
   string confTxt = StringFormat("信心%.0f%%", g_ai_judge.confidence);
   string waitFlip = (g_ai_flip_hits > 0 ? " 反向未确认" : "");
   if(g_ai_judge.freeze_orders)
      return meanTxt + "先别做 " + confTxt + " " + why;
   if(g_ai_judge.confidence < 50.0)
      return meanTxt + "不是趋势 " + confTxt + " 不开仓 " + why;
   if(g_ai_judge.confidence < 72.0)
     {
      int brk = SimilarBaseBreak();
      if(brk < 0)
        {
         if(NearSupport())
            return meanTxt + "支撑上先看回调 " + confTxt;
         return meanTxt + "前K差不多 跌破进 " + confTxt;
        }
      if(brk > 0)
        {
         if(NearResist())
            return meanTxt + "压力上先看回调 " + confTxt;
         return meanTxt + "前K差不多 突破进 " + confTxt;
        }
      if(MeasureRangeBox())
        {
         string boxTxt = StringFormat("10根高%.1f低%.1f ", g_chop_hi, g_chop_lo);
         int chop = ChopSide();
         if(chop > 0)
         {
            if(NearResist())
               return meanTxt + boxTxt + "压力上先看回调 " + confTxt;
            return meanTxt + boxTxt + "下沿均价下RSI做多 " + confTxt;
         }
         if(chop < 0)
         {
            if(NearSupport())
               return meanTxt + boxTxt + "支撑上先看回调 " + confTxt;
            return meanTxt + boxTxt + "上沿均价上RSI做空 " + confTxt;
         }
         return meanTxt + boxTxt + "等上下沿均价RSI " + confTxt;
        }
      return meanTxt + "震荡 等10根区间 " + confTxt + " " + why;
     }
   if(LongLineWatch())
      return meanTxt + "长线观望 " + confTxt + " 先看上次对错 " + why;
   int heldNow = DeepSeekOpenSide();
   int runNow = M5Leg();
   if(heldNow != 0 && runNow != 0 && heldNow != runNow)
      return meanTxt + "反向未确认 " + confTxt + waitFlip + " " + why;
   if(runNow > 0 && heldNow == runNow)
     {
      if(NearResist())
         return meanTxt + "压力上先看回调 " + confTxt;
      return meanTxt + "趋势做多 " + confTxt + (TrendDipReady(1) ? " 回落进 " : " 等高点回落 ") + why;
     }
   if(runNow < 0 && heldNow == runNow)
     {
      if(NearSupport())
         return meanTxt + "支撑上先看回调 " + confTxt;
      return meanTxt + "趋势做空 " + confTxt + (TrendDipReady(-1) ? " 回升进 " : " 等低点回升 ") + why;
     }
   if(MeasureChopBox())
     {
      int chop = ChopSide();
      string boxTxt = StringFormat("震荡%.0f点 ", g_chop_pts);
      if(g_ai_judge.confidence < 50.0)
         return meanTxt + boxTxt + confTxt + " 不开仓";
      if(chop > 0 && NearResist())
         return meanTxt + boxTxt + "压力上先看回调 " + confTxt;
      if(chop < 0 && NearSupport())
         return meanTxt + boxTxt + "支撑上先看回调 " + confTxt;
      if(chop > 0)
         return meanTxt + boxTxt + "下沿做多 " + confTxt;
      if(chop < 0)
         return meanTxt + boxTxt + "上沿做空 " + confTxt;
      return meanTxt + boxTxt + "等贴边 " + confTxt;
     }
   int timed = MeanExhaustSide();
   bool above = PriceAboveMean();
   if(DeepSeekTrend())
     {
      int side = DeepSeekOpenSide();
      if(side > 0)
         return meanTxt + "方向偏多 " + confTxt + " 等高点回落 " + why + waitFlip;
      if(side < 0)
         return meanTxt + "方向偏空 " + confTxt + " 等低点回升 " + why + waitFlip;
     }
   if(g_ai_judge.confidence < 50.0)
      return meanTxt + "中性 " + confTxt + " 不开仓 " + why;
   if(timed > 0 && NearResist())
      return meanTxt + "压力上先看回调 " + confTxt;
   if(timed < 0 && NearSupport())
      return meanTxt + "支撑上先看回调 " + confTxt;
   if(timed > 0)
      return meanTxt + "均价下 下跌无力做多 " + confTxt;
   if(timed < 0)
      return meanTxt + "均价上 上涨无力做空 " + confTxt;
   if(above)
      return meanTxt + "均价上 等上涨无力 " + confTxt;
   return meanTxt + "均价下 等下跌无力 " + confTxt;
  }

#ifdef EA_PANEL_WIN
// 矮面板先去掉三根均价，否则「信心」会被挤出屏幕。
string WinConfidenceLine()
  {
   string full = DeepSeekJudgeLine();
   int bar = StringFind(full, "| ");
   if(bar >= 0 && bar + 2 < StringLen(full))
      return StringSubstr(full, bar + 2);
   return full;
  }
#endif

void AiPrintBootBanner()
  {
   PrintFormat("EA v7.14：DeepSeek判断 EA只开仓 40秒 止盈%.0f 止损%.0f 开仓%s 冷却%d分 封顶%d层 AI=%s %s%s",
               g_BasketTP, g_BasketSL_Money, OpenSessionText(),
               g_BasketSL_CooldownSec / 60, g_MaxLayers,
               (AiDrivesEntry() ? "自动开" : (UseExternalAI ? "只显示" : "关")),
               (!UseSharedConfig ? "本地" : (SharedConfigMaster ? "主号" : "从号")),
               (BotFullyPaused() ? " 暂停中" : ""));
  }

void AiDrawPanelLines(const int bx, const int y0, const color colMuted)
  {
   for(int i = 0; i < 7; i++)
      ObjectDelete(0, UI_PREFIX + "AI" + IntegerToString(i));
   if(!UseExternalAI)
      return;

   color aiCol = UI_COL_TITLE;
   if(g_ai_judge.from_external_ai && g_ai_judge.freeze_orders)
      aiCol = UI_COL_RED;
   else if(g_ai_judge.from_external_ai)
      aiCol = UI_COL_GREEN;

   int n = g_ai_panel_n;
   if(n <= 0)
     {
      UiSetLabel(UI_PREFIX + "AI0", bx, y0, "AI辅助：加载中…", aiCol, UI_SMALL_SIZE);
      return;
     }
   for(int i = 0; i < n && i < AI_PANEL_LINE_MAX; i++)
     {
      color c = (i == 0 ? aiCol : colMuted);
      UiSetLabel(UI_PREFIX + "AI" + IntegerToString(i),
                 bx, y0 + i * UI_ROW,
                 g_ai_panel_lines[i], c, UI_SMALL_SIZE);
     }
  }

void AiRefreshAssist()
  {
   if(!UseExternalAI)
     {
      AutoJudge_Clear(g_ai_judge);
      AutoJudge_ClearLevelObjects();
      AiPanelClearLines();
      return;
     }

   datetime now = TimeCurrent();
   int snapSec = MathMax(3, AiSnapshotSec);
   if(now - g_ai_last_snapshot >= snapSec)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      int buyN  = CountPositions(POSITION_TYPE_BUY, true);
      int sellN = CountPositions(POSITION_TYPE_SELL, true);
      double buyLot  = SumVolume(POSITION_TYPE_BUY, true);
      double sellLot = SumVolume(POSITION_TYPE_SELL, true);
      double buyP  = BasketProfit(POSITION_TYPE_BUY, false, true);
      double sellP = BasketProfit(POSITION_TYPE_SELL, false, true);
      double sprPts = (double)g_spread_max_2h_pts * _Point;
      double adx = AiReadIndicatorShift(g_ai_adx_handle, 0, 1);
      double rsi = AiReadIndicatorShift(g_ai_rsi_handle, 0, 1);
      if(rsi <= 0.0)
         rsi = 50.0;
      // 只用已经收盘的那根 M1，正在走的这根不参与方向
      double ema5  = AiReadIndicatorShift(g_ai_ema5_handle, 0, 1);
      double ema10 = AiReadIndicatorShift(g_ai_ema10_handle, 0, 1);
      double ema20 = AiReadIndicatorShift(g_ai_ema20_handle, 0, 1);
      double ema5prev = AiReadIndicatorShift(g_ai_ema5_handle, 0, 2);
      double ema10prev = AiReadIndicatorShift(g_ai_ema10_handle, 0, 2);
      double close1 = iClose(_Symbol, PERIOD_M5, 1);
      string maState = "纠缠";
      // 排列还要均线本身在走，刚粘上不算
      if(close1 > ema5 && ema5 > ema10 && ema10 > ema20 &&
         ema5 > ema5prev && ema10 > ema10prev && ema5prev > 0.0)
         maState = "多头排列";
      else if(close1 < ema5 && ema5 < ema10 && ema10 < ema20 &&
              ema5 < ema5prev && ema10 < ema10prev && ema5 > 0.0)
         maState = "空头排列";
      double macdMain = AiReadIndicatorShift(g_chart_macd, 0, 1);
      double macdSig  = AiReadIndicatorShift(g_chart_macd, 1, 1);
      double stochK   = AiReadIndicatorShift(g_chart_stoch, 0, 1);
      double stochD   = AiReadIndicatorShift(g_chart_stoch, 1, 1);
      if(g_chart_rsi != INVALID_HANDLE)
        {
         double rsiM5 = AiReadIndicatorShift(g_chart_rsi, 0, 1);
         if(rsiM5 > 0.0)
            rsi = rsiM5;
        }
      if(g_chart_adx != INVALID_HANDLE)
        {
         double adxM5 = AiReadIndicatorShift(g_chart_adx, 0, 1);
         if(adxM5 > 0.0)
            adx = adxM5;
        }
      AutoJudge_WriteSnapshot(
         _Symbol, bid, ask, buyN, sellN, buyLot, sellLot, buyP, sellP,
         adx, rsi, PERIOD_M5, CalcRange2HUSD(), sprPts,
         ema5, ema10, ema20, ema5prev, maState,
         macdMain, macdSig, stochK, stochD,
         g_BasketTP, g_BasketSL_Money, g_OpenStartHHMM, g_OpenEndHHMM);
      g_ai_last_snapshot = now;
     }

   if(now - g_ai_last_load < 2 && g_ai_judge.from_external_ai && g_ai_panel_n > 0)
      return;
   g_ai_last_load = now;

   JudgeResult j;
   AutoJudge_Clear(j);
   if(!AutoJudge_ReadTeach(j, AiSignalMaxAgeSec))
     {
      AutoJudge_Clear(g_ai_judge);
      AiPanelClearLines();
      AiPanelAddLine(AiBridgeOn() ? "支撑 -" : "AI未开，不下单");
      AiPanelAddLine("压力 -");
      AutoJudge_ClearLevelObjects();
      return;
     }

   g_ai_judge = j;
   AutoJudge_DrawLevels(j);

   AiPanelClearLines();
   AiPanelAddLine(PanelLevelText("支撑", j.support1));
   AiPanelAddLine(PanelLevelText("压力", j.resist1));
  }
#else
int AiPanelExtraRows()
  {
   return 0;
  }

void AiClearLevelObjectsSafe()
  {
  }

void AiReleaseIndicators()
  {
  }

void AiOnInitReset()
  {
  }

void AiPrintBootBanner()
  {
   PrintFormat("EA v7.13：手开+间距 新闻清仓 止损%.0f 开仓%s 冷却%d分 封顶%d层 %s%s",
               g_BasketSL_Money, OpenSessionText(), g_BasketSL_CooldownSec / 60, g_MaxLayers,
               (!UseSharedConfig ? "本地" : (SharedConfigMaster ? "主号" : "从号")),
               (BotFullyPaused() ? " 暂停中" : ""));
  }

void AiDrawPanelLines(const int bx, const int y0, const color colMuted)
  {
   for(int i = 0; i < 7; i++)
      ObjectDelete(0, UI_PREFIX + "AI" + IntegerToString(i));
  }

void AiRefreshAssist()
  {
  }
#endif


bool IsOurPosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;
   return (PositionGetInteger(POSITION_MAGIC) == MagicBase &&
           PositionGetString(POSITION_SYMBOL) == _Symbol);
  }

bool IsHedgeComment(const string cmt)
  {
   return (StringFind(cmt, "HEDGE") >= 0);
  }

bool IsSelectedHedge()
  {
   return IsHedgeComment(PositionGetString(POSITION_COMMENT));
  }

int CountPositions(const int typeFilter = -1, const bool gridOnly = false)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(gridOnly && IsSelectedHedge())
         continue;
      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      if(typeFilter < 0 || ptype == typeFilter)
         count++;
     }
   return count;
  }

double SumVolume(const int typeFilter = -1, const bool gridOnly = false)
  {
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(gridOnly && IsSelectedHedge())
         continue;
      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      if(typeFilter >= 0 && ptype != typeFilter)
         continue;
      lots += PositionGetDouble(POSITION_VOLUME);
     }
   return lots;
  }

double AvgOpenPrice(const int typeFilter, const bool gridOnly = true)
  {
   double vol = 0.0;
   double pxv = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(gridOnly && IsSelectedHedge())
         continue;
      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      if(ptype != typeFilter)
         continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      vol += v;
      pxv += v * PositionGetDouble(POSITION_PRICE_OPEN);
     }
   if(vol <= 0.0)
      return 0.0;
   return pxv / vol;
  }

bool BotFullyPaused()
  {
   return (g_pause_buy && g_pause_sell);
  }

double BasketProfit(const int typeFilter = -1, const bool hedgeOnly = false, const bool gridOnly = false)
  {
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      bool hed = IsSelectedHedge();
      if(hedgeOnly && !hed)
         continue;
      if(gridOnly && hed)
         continue;
      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      if(typeFilter >= 0 && ptype != typeFilter)
         continue;
      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return profit;
  }

double LastOpenPrice(const int posType, bool &found, const bool gridOnly = true)
  {
   found = false;
   double price = 0.0;
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(gridOnly && IsSelectedHedge())
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || t >= lastTime)
        {
         found = true;
         lastTime = t;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   return price;
  }

double LastLot(const int posType, bool &found, const bool gridOnly = true)
  {
   found = false;
   double lot = 0.0;
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(gridOnly && IsSelectedHedge())
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || t >= lastTime)
        {
         found = true;
         lastTime = t;
         lot = PositionGetDouble(POSITION_VOLUME);
        }
     }
   return lot;
  }

// 最后一手与上一手（网格）开仓价、最后一手浮盈
bool GetLastTwoGrid(const int posType, double &lastPrice, double &prevPrice,
                    double &lastProfit, bool &hasPrev)
  {
   lastPrice = 0.0;
   prevPrice = 0.0;
   lastProfit = 0.0;
   hasPrev = false;

   datetime t1 = 0, t2 = 0;
   double p1 = 0.0, p2 = 0.0, pr1 = 0.0;
   bool got1 = false, got2 = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(IsSelectedHedge())
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      double px = PositionGetDouble(POSITION_PRICE_OPEN);
      double pr = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(!got1 || t >= t1)
        {
         // 原第一变为第二
         if(got1)
           {
            t2 = t1;
            p2 = p1;
            got2 = true;
           }
         t1 = t;
         p1 = px;
         pr1 = pr;
         got1 = true;
        }
      else if(!got2 || t >= t2)
        {
         t2 = t;
         p2 = px;
         got2 = true;
        }
     }

   if(!got1)
      return false;
   lastPrice = p1;
   lastProfit = pr1;
   if(got2)
     {
      prevPrice = p2;
      hasPrev = true;
     }
   return true;
  }

double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0)
      stepLot = 0.01;
   lot = MathRound(lot / stepLot) * stepLot;
   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;
   int digits = 0;
   double s = stepLot;
   while(s < 1.0 && digits < 8)
     {
      s *= 10.0;
      digits++;
     }
   return NormalizeDouble(lot, digits);
  }

double NextMartinLot(const int posType)
  {
   bool found = false;
   double last = LastLot(posType, found, true);
   if(!found)
      return NormalizeLot(g_InitLot);
   double next = last * g_MartinMult;
   double norm = NormalizeLot(next);
   if(g_MartinMult > 1.0 && norm <= last + 1e-8)
     {
      double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(stepLot <= 0)
         stepLot = 0.01;
      norm = NormalizeLot(last + stepLot);
     }
   return norm;
  }

double CurrentGridStepUSD(const int layers)
  {
   // 封顶15层内只用一个间距；layers 参数保留兼容调用处
   return g_GridStepUSD;
  }

bool SpreadOK()
  {
   long spr = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spr <= g_MaxSpreadPoints)
      return true;
   static datetime lastWarn = 0;
   if(TimeCurrent() - lastWarn >= 30)
     {
      PrintFormat("点差过大不开仓: 当前=%I64d 上限=%d", spr, g_MaxSpreadPoints);
      lastWarn = TimeCurrent();
     }
   return false;
  }

void CloseAllOurPositions(const string reason)
  {
   PrintFormat("开始全平: %s | 浮盈=%.2f 持仓=%d", reason, BasketProfit(-1), CountPositions());
   trade.SetExpertMagicNumber(MagicBase);
   trade.SetDeviationInPoints(50);
   // 多扫几轮，避免一次失败残留
   for(int pass = 0; pass < 3; pass++)
     {
      int left = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(!IsOurPosition(ticket))
            continue;
         left++;
         if(!trade.PositionClose(ticket))
            PrintFormat("平仓失败 %I64u: %s (retcode=%d)",
                        ticket, trade.ResultRetcodeDescription(), (int)trade.ResultRetcode());
        }
      if(left <= 0)
         break;
      Sleep(200);
     }
   g_hedge_against = -1;
   PrintFormat("全平结束: %s | 剩余本EA仓=%d", reason, CountPositions());
  }

// 只平 AI 单。专家/人工单留着，等篮子止盈或止损。
void CloseAiBarPositions(const string reason)
  {
   trade.SetExpertMagicNumber(MagicBase);
   trade.SetDeviationInPoints(50);
   int closed = 0;
   for(int pass = 0; pass < 3; pass++)
     {
      int left = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(!IsOurPosition(ticket))
            continue;
         string cmt = PositionGetString(POSITION_COMMENT);
         if(CommentIsManual(cmt))
            continue;
         if(!CommentIsAi(cmt) && g_manual_hold)
            continue;
         left++;
         if(trade.PositionClose(ticket))
            closed++;
         else
            PrintFormat("平仓失败 %I64u: %s", ticket, trade.ResultRetcodeDescription());
        }
      if(left <= 0)
         break;
      Sleep(200);
     }
   if(CountAiSettlePositions() <= 0)
      g_ai_entry_bar = 0;
   PrintFormat("AI单K线结束平仓: %s | 平掉%d 剩余AI=%d", reason, closed, CountAiSettlePositions());
  }

void CloseOurPositionsByType(const int posType, const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      if(!trade.PositionClose(ticket))
         PrintFormat("平仓失败 %I64u: %s", ticket, trade.ResultRetcodeDescription());
     }
   Print("平仓: ", reason);
  }

// 网格单按开仓时间从旧到新；tickets[0] 永远是「第一单」
int CollectGridTicketsOldestFirst(const int posType, ulong &tickets[], const int maxN)
  {
   ArrayResize(tickets, 0);
   if(maxN <= 0)
      return 0;
   ulong raw[];
   datetime times[];
   int n = 0;
   ArrayResize(raw, 0);
   ArrayResize(times, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(IsSelectedHedge())
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      int m = n;
      ArrayResize(raw, m + 1);
      ArrayResize(times, m + 1);
      raw[m] = ticket;
      times[m] = (datetime)PositionGetInteger(POSITION_TIME);
      n++;
     }
   // 冒泡：旧→新
   for(int a = 0; a < n - 1; a++)
     {
      for(int b = 0; b < n - 1 - a; b++)
        {
         if(times[b] > times[b + 1])
           {
            datetime td = times[b]; times[b] = times[b + 1]; times[b + 1] = td;
            ulong tk = raw[b]; raw[b] = raw[b + 1]; raw[b + 1] = tk;
           }
        }
     }
   int outN = n;
   if(outN > maxN)
      outN = maxN;
   ArrayResize(tickets, outN);
   for(int k = 0; k < outN; k++)
      tickets[k] = raw[k];
   return n; // 返回实际总层数（可能 > maxN）
  }

ulong OldestGridTicket(const int posType)
  {
   ulong tickets[];
   int total = CollectGridTicketsOldestFirst(posType, tickets, 1);
   if(total <= 0 || ArraySize(tickets) <= 0)
      return 0;
   return tickets[0];
  }

bool CloseFirstOfSide(const int posType, const string reason)
  {
   ulong ticket = OldestGridTicket(posType);
   if(ticket == 0 || !PositionSelectByTicket(ticket))
     {
      PrintFormat("%s → 无%s第一单可平", reason, (posType == POSITION_TYPE_BUY ? "多" : "空"));
      g_last_close_info = StringFormat("无%s#1可平", (posType == POSITION_TYPE_BUY ? "多" : "空"));
      g_last_close_col = UI_COL_MUTED;
      return false;
     }
   double lot = PositionGetDouble(POSITION_VOLUME);
   double px  = PositionGetDouble(POSITION_PRICE_OPEN);
   double pr  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   trade.SetExpertMagicNumber(MagicBase);
   trade.SetDeviationInPoints(50);
   if(!trade.PositionClose(ticket))
     {
      PrintFormat("%s → 平#1失败 %I64u: %s", reason, ticket, trade.ResultRetcodeDescription());
      g_last_close_info = StringFormat("平%s#1失败", (posType == POSITION_TYPE_BUY ? "多" : "空"));
      g_last_close_col = UI_COL_RED;
      return false;
     }
   g_last_close_info = StringFormat("刚平%s#1  %.2f手 @%s  盈亏%+.2f",
                                    (posType == POSITION_TYPE_BUY ? "多" : "空"),
                                    lot, DoubleToString(px, _Digits), pr);
   g_last_close_col = (pr >= 0.0 ? UI_COL_GREEN : UI_COL_RED);
   PrintFormat("%s → %s", reason, g_last_close_info);
   return true;
  }

void CloseAllHedgePositions(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(!IsSelectedHedge())
         continue;
      if(!trade.PositionClose(ticket))
         PrintFormat("平对冲失败 %I64u: %s", ticket, trade.ResultRetcodeDescription());
     }
   g_hedge_against = -1;
   Print("取消对冲: ", reason);
  }

bool OldestOurPositionInLoss()
  {
   bool found = false;
   datetime oldest = 0;
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(!found || t < oldest)
        {
         found = true;
         oldest = t;
         profit = p;
        }
     }
   return (found && profit < 0.0);
  }

double ActiveBasketTP()
  {
   return g_BasketTP;
  }

void PanelPushSharedIfMaster()
  {
   g_shared_last_sig = CfgSignature();
   if(UseSharedConfig && IsCmdMaster())
     {
      if(CfgWriteShared())
         Print("共享配置已更新(面板)");
     }
  }

void ApplyTpFromPanel(const double v)
  {
   if(v < 1.0)
     {
      Print("止盈过小，已忽略");
      return;
     }
   if(UseSharedConfig && !IsCmdMaster())
     {
      Print("从号请在主号改止盈");
      return;
     }
   g_BasketTP = v;
   PrintFormat("止盈已更新: %.2f", g_BasketTP);
   g_tp_edit_focus = false;
   if(ObjectFind(0, EDIT_TP) >= 0)
      ObjectSetString(0, EDIT_TP, OBJPROP_TEXT, DoubleToString(g_BasketTP, 0));
   PanelPushSharedIfMaster();
  }

// 面板止损填正数=最大亏损金额，内部存负数
void ApplySlFromPanel(const double vAbs)
  {
   double absLoss = MathAbs(vAbs);
   if(absLoss < 1.0)
     {
      Print("止损过小，已忽略");
      return;
     }
   if(UseSharedConfig && !IsCmdMaster())
     {
      Print("从号请在主号改止损");
      return;
     }
   g_BasketSL_Money = -absLoss;
   PrintFormat("止损已更新: %.2f (浮亏达此全平)", g_BasketSL_Money);
   g_sl_edit_focus = false;
   if(ObjectFind(0, EDIT_SL) >= 0)
      ObjectSetString(0, EDIT_SL, OBJPROP_TEXT, DoubleToString(absLoss, 0));
   PanelPushSharedIfMaster();
  }

void ApplyLotFromPanel(const double v)
  {
   if(v < 0.0)
     {
      Print("起手不能为负，已忽略");
      return;
     }
   if(UseSharedConfig && !IsCmdMaster())
     {
      Print("从号请在主号改起手");
      return;
     }
   // 0=禁止开仓；>0 按品种手数规范化
   g_InitLot = (v <= 0.0 ? 0.0 : NormalizeLot(v));
   PrintFormat("起手已更新: %.2f%s", g_InitLot, (g_InitLot <= 0.0 ? "（0=不开仓）" : ""));
   g_lot_edit_focus = false;
   if(ObjectFind(0, EDIT_LOT) >= 0)
      ObjectSetString(0, EDIT_LOT, OBJPROP_TEXT, DoubleToString(g_InitLot, 2));
   PanelPushSharedIfMaster();
  }

double PanelSlAbs()
  {
   return MathAbs(g_BasketSL_Money);
  }

double ProfitTrailDistance()
  {
   if(g_ProfitTrailUSD > 0.0)
      return g_ProfitTrailUSD;
   return MathAbs(g_BasketSL_Money);
  }

bool CheckProfitExits()
  {
   if(CountPositions() <= 0)
     {
      g_peak_all_profit = 0.0;
      return false;
     }

   // 从号不自行止盈止损，只跟主号指令（避免两边盈亏差导致不同步）
   if(UseSharedConfig && !IsCmdMaster())
      return false;

   double buyProfit  = BasketProfit(POSITION_TYPE_BUY, false, true);
   double sellProfit = BasketProfit(POSITION_TYPE_SELL, false, true);
   double allProfit  = BasketProfit(-1);
   double tpNeed     = g_BasketTP;
   bool acted = false;

   // 跟踪本轮最高总浮盈（用于锁利）
   if(allProfit > g_peak_all_profit)
      g_peak_all_profit = allProfit;

   // 多空分篮止盈：各边浮盈独立达标，只平该边
   if(tpNeed > 0.0)
     {
      if(buyProfit >= tpNeed && CountPositions(POSITION_TYPE_BUY, true) > 0)
        {
         string why = StringFormat("多篮止盈 %.2f>=%.2f", buyProfit, tpNeed);
         if(UseSharedConfig && IsCmdMaster())
            MasterBroadcastCmd("CLOSE_BUY");
         else
            CloseOurPositionsByType(POSITION_TYPE_BUY, why);
         Print(why);
         acted = true;
        }
      if(sellProfit >= tpNeed && CountPositions(POSITION_TYPE_SELL, true) > 0)
        {
         string why = StringFormat("空篮止盈 %.2f>=%.2f", sellProfit, tpNeed);
         if(UseSharedConfig && IsCmdMaster())
            MasterBroadcastCmd("CLOSE_SELL");
         else
            CloseOurPositionsByType(POSITION_TYPE_SELL, why);
         Print(why);
         acted = true;
        }
     }

   // 浮盈锁利：峰值已超过回撤额（扣去止损/回撤后仍有赚），
   // 一旦总浮盈从峰值回撤到「峰值-回撤额」→ 全平（盈利出场，不进止损冷却）
   if(g_UseProfitTrailLock)
     {
      double trail = ProfitTrailDistance();
      if(trail > 0.0 && g_peak_all_profit > trail)
        {
         double lockLine = g_peak_all_profit - trail;
         if(lockLine > 0.0 && allProfit <= lockLine)
           {
            string why = StringFormat(
               "浮盈锁利 峰值%.2f 回撤%.2f 现%.2f<=锁利线%.2f",
               g_peak_all_profit, trail, allProfit, lockLine);
            if(UseSharedConfig && IsCmdMaster())
               MasterBroadcastCmd("CLOSE_ALL");
            else
               CloseAllOurPositions(why);
            Print(why);
            g_peak_all_profit = 0.0;
            acted = true;
            return acted;
           }
        }
     }

   // 总止损：多+空合计，触发后冷却（默认30分钟）再允许开仓
   if(g_BasketSL_Money < 0.0 && allProfit <= g_BasketSL_Money)
     {
      string why = StringFormat("全部止损 %.2f<=%.2f", allProfit, g_BasketSL_Money);
      if(UseSharedConfig && IsCmdMaster())
         MasterBroadcastCmd("CLOSE_ALL");
      else
         CloseAllOurPositions(why);
      int cool = MathMax(0, g_BasketSL_CooldownSec);
      g_sl_pause_until = TimeCurrent() + cool;
      PrintFormat("%s，冷却 %d 分钟后再开仓", why, cool / 60);
      g_peak_all_profit = 0.0;
      acted = true;
     }
   return acted;
  }

// 刚进入美高影响新闻窗口 → 立刻清空本EA持仓（窗口内仍禁开）
void ManageNewsFlatten()
  {
   const bool frozen = NewsCalendar_IsFrozen();
   if(frozen && !g_news_was_frozen)
     {
      if(CountPositions() > 0)
        {
         string why = StringFormat("新闻清空持仓: %s", g_news.event_name);
         if(UseSharedConfig && IsCmdMaster())
            MasterBroadcastCmd("CLOSE_ALL");
         else
            CloseAllOurPositions(why);
         PrintFormat("%s | 窗口内禁止新开仓", why);
        }
      else
         PrintFormat("进入新闻窗口(无持仓): %s", g_news.event_name);
     }
   g_news_was_frozen = frozen;
  }

bool ShouldSkipOrCancelHedge(const int heavyType)
  {
   double lastPx, prevPx, lastPr;
   bool hasPrev = false;
   if(!GetLastTwoGrid(heavyType, lastPx, prevPx, lastPr, hasPrev))
      return false;
   if(lastPr <= 0.0)
      return false;
   if(!hasPrev)
      return false;
   double gap = MathAbs(lastPx - prevPx);
   return (gap <= HedgeSkipGapUSD);
  }

int HeavyGridSide(int &buyN, int &sellN)
  {
   buyN = CountPositions(POSITION_TYPE_BUY, true);
   sellN = CountPositions(POSITION_TYPE_SELL, true);
   if(buyN >= sellN && buyN > 0)
      return POSITION_TYPE_BUY;
   if(sellN > buyN)
      return POSITION_TYPE_SELL;
   return -1;
  }

bool HasHedgePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(IsSelectedHedge())
         return true;
     }
   return false;
  }

void ChiselOpposingWithHedgeProfit()
  {
   if(g_hedge_against < 0 || !HasHedgePositions())
      return;
   double hp = BasketProfit(-1, true, false); // 仅对冲单盈亏
   if(hp <= 0.0)
      return;

   // 按开仓时间从旧到新削重仓边网格单
   while(hp > 0.0)
     {
      ulong best = 0;
      datetime oldest = 0;
      bool found = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(!IsOurPosition(ticket))
            continue;
         if(IsSelectedHedge())
            continue;
         if((int)PositionGetInteger(POSITION_TYPE) != g_hedge_against)
            continue;
         datetime t = (datetime)PositionGetInteger(POSITION_TIME);
         if(!found || t < oldest)
           {
            found = true;
            oldest = t;
            best = ticket;
           }
        }
      if(!found || best == 0)
         break;
      if(!PositionSelectByTicket(best))
         break;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pr = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if(pr >= 0.0)
        {
         if(!trade.PositionClose(best))
            break;
         continue;
        }
      // 亏损单：盈利额度内能平多少平多少
      if(-pr <= hp + 1e-6)
        {
         if(!trade.PositionClose(best))
            break;
         hp += pr;
        }
      else
        {
         double frac = hp / (-pr);
         double closeVol = NormalizeLot(vol * frac);
         if(closeVol < minLot)
            break;
         if(closeVol >= vol)
           {
            if(!trade.PositionClose(best))
               break;
           }
         else
           {
            if(!trade.PositionClosePartial(best, closeVol))
               break;
           }
         break;
        }
     }
  }

void ManageHedgeLogic()
  {
   int buyN = 0, sellN = 0;
   int heavy = HeavyGridSide(buyN, sellN);
   int sideMax = MathMax(buyN, sellN);

   // 已有对冲：检查取消条件
   if(HasHedgePositions())
     {
      int against = g_hedge_against;
      if(against < 0)
         against = heavy;
      if(against >= 0 && ShouldSkipOrCancelHedge(against))
        {
         CloseAllHedgePositions("对立边最后一手盈利且与上一手价差<=3");
         return;
        }
      ChiselOpposingWithHedgeProfit();
      return;
     }

   if(!CanOpenNewOrders())
      return;
   if(HedgeAfterLayers <= 0 || heavy < 0 || sideMax < HedgeAfterLayers)
      return;
   if(ShouldSkipOrCancelHedge(heavy))
      return;

   double heavyLots = SumVolume(heavy, true);
   double need = NormalizeLot(heavyLots * HedgeLotMult);
   if(need <= 0.0)
      return;

   ENUM_ORDER_TYPE otype = (heavy == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   if(!CanOpenNewOrders() || NewsCalendar_IsFrozen() || !SpreadOK())
      return;
   trade.SetExpertMagicNumber(MagicBase);
   trade.SetDeviationInPoints(30);
   double price = (otype == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string cmt = OrderCommentText + "|HEDGE";
   bool ok = (otype == ORDER_TYPE_BUY)
             ? trade.Buy(need, _Symbol, price, 0, 0, cmt)
             : trade.Sell(need, _Symbol, price, 0, 0, cmt);
   if(ok)
     {
      g_hedge_against = heavy;
      datetime now = TimeCurrent();
      g_lastAddTime = now;
      if(otype == ORDER_TYPE_BUY)
         g_lastAddBuy = now;
      else
         g_lastAddSell = now;
      PrintFormat("启动对冲: 重仓边=%s 层=%d 对冲手=%.2f (x%.1f)",
                  (heavy == POSITION_TYPE_BUY ? "多" : "空"),
                  sideMax, need, HedgeLotMult);
     }
   else
      PrintFormat("对冲开仓失败: %s", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void CreatePanelButton(const string name, const string text,
                       const int x, const int y, const int w, const int h,
                       const color bg, const color fg = clrWhite)
  {
   const bool created = (ObjectFind(0, name) < 0);
   if(created)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, UI_FONT);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, UI_BTN_FONT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'255,255,255');
   if(created)
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 2000);
  }

void RefreshPanelButtons()
  {
   const int x0 = 12;
   const int y0 = g_ui_btn_y;
   const int gap = UI_BTN_GAP;
   const int bw = (UI_PANEL_W - 36 - 3 * gap) / 4;
   const bool paused = BotFullyPaused();
   const bool master = IsEntryMaster();
   const int entryW = (UI_PANEL_W - 36 - gap) / 2;
   // 第一行：入场多 | 入场空
   CreatePanelButton(BTN_ENTRY_BUY, (master ? "入场多" : "跟多"),
                     x0, y0, entryW, UI_BTN_H,
                     (master ? C'20,160,90' : C'45,80,60'));
   CreatePanelButton(BTN_ENTRY_SELL, (master ? "入场空" : "跟空"),
                     x0 + entryW + gap, y0, entryW, UI_BTN_H,
                     (master ? C'210,50,50' : C'90,55,55'));
   // 第二行：平多#1 | 平空#1（永远平队列最上面那单）
   const int y1 = y0 + UI_BTN_H + UI_BTN_GAP;
   const int firstW = (UI_PANEL_W - 36 - gap) / 2;
   CreatePanelButton(BTN_CLOSE_FIRST_BUY, (master ? "平多#1" : "跟平多#1"),
                     x0, y1, firstW, UI_BTN_H, C'16,130,75');
   CreatePanelButton(BTN_CLOSE_FIRST_SELL, (master ? "平空#1" : "跟平空#1"),
                     x0 + firstW + gap, y1, firstW, UI_BTN_H, C'180,45,45');
   // 第三行：平多 | 平空 | 暂停 | 全部平仓
   const int y2 = y1 + UI_BTN_H + UI_BTN_GAP;
   CreatePanelButton(BTN_CLOSE_BUY, "平多",
                     x0, y2, bw, UI_BTN_H, C'20,160,90');
   CreatePanelButton(BTN_CLOSE_SELL, "平空",
                     x0 + (bw + gap), y2, bw, UI_BTN_H, C'210,50,50');
   CreatePanelButton(BTN_PAUSE, (paused ? "恢复" : "暂停"),
                     x0 + 2 * (bw + gap), y2, bw, UI_BTN_H,
                     (paused ? C'40,120,220' : C'70,78,92'));
   CreatePanelButton(BTN_CLOSE_ALL, UI_BTN_ALL_TEXT,
                     x0 + 3 * (bw + gap), y2, bw, UI_BTN_H, C'220,130,30');
   ObjectDelete(0, BTN_ENTRY);
   ObjectDelete(0, BTN_CLOSE_SIDE);
   ObjectDelete(0, BTN_PAUSE_BUY);
   ObjectDelete(0, BTN_PAUSE_SELL);
  }

void DeletePanelButtons()
  {
   ObjectDelete(0, BTN_ENTRY);
   ObjectDelete(0, BTN_ENTRY_BUY);
   ObjectDelete(0, BTN_ENTRY_SELL);
   ObjectDelete(0, BTN_PAUSE);
   ObjectDelete(0, BTN_PAUSE_BUY);
   ObjectDelete(0, BTN_PAUSE_SELL);
   ObjectDelete(0, BTN_CLOSE_BUY);
   ObjectDelete(0, BTN_CLOSE_SELL);
   ObjectDelete(0, BTN_CLOSE_FIRST_BUY);
   ObjectDelete(0, BTN_CLOSE_FIRST_SELL);
   ObjectDelete(0, BTN_CLOSE_SIDE);
   ObjectDelete(0, BTN_CLOSE_ALL);
   ObjectDelete(0, BTN_TP_APPLY);
   ObjectDelete(0, BTN_TP_MINUS);
   ObjectDelete(0, BTN_TP_PLUS);
   ObjectDelete(0, BTN_SL_APPLY);
   ObjectDelete(0, BTN_SL_MINUS);
   ObjectDelete(0, BTN_SL_PLUS);
   ObjectDelete(0, BTN_LOT_APPLY);
   ObjectDelete(0, BTN_LOT_MINUS);
   ObjectDelete(0, BTN_LOT_PLUS);
   ObjectDelete(0, BTN_SIDE_APPLY);
   ObjectDelete(0, EDIT_TP);
   ObjectDelete(0, EDIT_SL);
   ObjectDelete(0, EDIT_LOT);
   ObjectDelete(0, EDIT_TP_BUY);
   ObjectDelete(0, EDIT_TP_SELL);
  }

void UiSetEdit(const string name, const int x, const int y, const int w, const int h,
               const string text, const bool allow_text_update)
  {
   const bool created = (ObjectFind(0, name) < 0);
   if(created)
      ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_FONT, UI_FONT);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, UI_EDIT_FONT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C'230,235,240');
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'40,46,56');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'90,100,115');
   ObjectSetInteger(0, name, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetInteger(0, name, OBJPROP_READONLY, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 600);
   if(created)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   else if(allow_text_update)
     {
      string cur = ObjectGetString(0, name, OBJPROP_TEXT);
      if(cur != text)
         ObjectSetString(0, name, OBJPROP_TEXT, text);
     }
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
  }

void UiSetMiniBtn(const string name, const int x, const int y, const int w, const int h,
                  const string text, const color bg)
  {
   const bool created = (ObjectFind(0, name) < 0);
   if(created)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, UI_FONT);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, UI_MINI_FONT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'60,70,85');
   if(created)
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 500);
  }

void CreateParamRow(const string labelName, const string label,
                    const string editName, const string editText, const bool allowEditUpdate,
                    const string btnMinus, const string minusTxt,
                    const string btnPlus, const string plusTxt,
                    const string btnApply,
                    const int x, const int y)
  {
   UiSetLabel(labelName, x, y + 8, label, C'220,220,220', UI_FONT_SIZE);
   UiSetEdit(editName, x + 52, y, 84, UI_CTRL_H, editText, allowEditUpdate);
   UiSetMiniBtn(btnMinus, x + 144, y, 48, UI_CTRL_H, minusTxt, C'70,75,85');
   UiSetMiniBtn(btnPlus,  x + 198, y, 48, UI_CTRL_H, plusTxt, C'40,120,90');
   UiSetMiniBtn(btnApply, x + 252, y, 64, UI_CTRL_H, "应用", C'40,100,180');
  }

void CreateParamControls(const int x, const int y)
  {
   // 面板上起手/止盈/止损编辑已取消，改参数用 F7 输入；清掉旧控件残留
   ObjectDelete(0, EDIT_TP);
   ObjectDelete(0, EDIT_SL);
   ObjectDelete(0, EDIT_LOT);
   ObjectDelete(0, BTN_TP_MINUS);
   ObjectDelete(0, BTN_TP_PLUS);
   ObjectDelete(0, BTN_TP_APPLY);
   ObjectDelete(0, BTN_SL_MINUS);
   ObjectDelete(0, BTN_SL_PLUS);
   ObjectDelete(0, BTN_SL_APPLY);
   ObjectDelete(0, BTN_LOT_MINUS);
   ObjectDelete(0, BTN_LOT_PLUS);
   ObjectDelete(0, BTN_LOT_APPLY);
   ObjectDelete(0, UI_PREFIX + "TP_L");
   ObjectDelete(0, UI_PREFIX + "SL_L");
   ObjectDelete(0, UI_PREFIX + "LOT_L");
   g_ui_controls_ready = true;
  }

void CreateTpControls(const int x, const int y)
  {
   CreateParamControls(x, y);
  }

void CreateSideTpControls(const int x, const int y)
  {
   // 已取消单边止盈控件
  }

void ApplySideTpFromPanel()
  {
   // 已取消单边止盈编辑，保留空函数兼容旧事件
  }

void HandlePanelClick(const string name)
  {
   // 面板所有交易指令：仅主号发令，从号跟随
   if(name == BTN_ENTRY_BUY)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd("OPEN_BUY");
      else
         Print("从号请等主号点「入场多」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_ENTRY_SELL)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd("OPEN_SELL");
      else
         Print("从号请等主号点「入场空」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_CLOSE_FIRST_BUY)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd("CLOSE_FIRST_BUY");
      else
         Print("从号请等主号点「平多#1」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_CLOSE_FIRST_SELL)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd("CLOSE_FIRST_SELL");
      else
         Print("从号请等主号点「平空#1」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_CLOSE_BUY)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd("CLOSE_BUY");
      else
         Print("从号请等主号点「平多」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_CLOSE_SELL)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd("CLOSE_SELL");
      else
         Print("从号请等主号点「平空」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_CLOSE_ALL || name == BTN_CLOSE_SIDE)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd("CLOSE_ALL");
      else
         Print("从号请等主号点「全部平仓」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_PAUSE || name == BTN_PAUSE_BUY || name == BTN_PAUSE_SELL)
     {
      if(IsCmdMaster())
         MasterBroadcastCmd(BotFullyPaused() ? "RESUME" : "PAUSE");
      else
         Print("从号请等主号点「暂停/恢复」");
      UpdateDashboard();
      return;
     }
   if(name == BTN_ENTRY)
     {
      Print("旧入场按钮已废弃，请用「入场多/入场空」");
      return;
     }
   if(name == BTN_TP_MINUS)
     {
      ApplyTpFromPanel(MathMax(1.0, ActiveBasketTP() - 10.0));
      UpdateDashboard();
      return;
     }
   if(name == BTN_TP_PLUS)
     {
      ApplyTpFromPanel(ActiveBasketTP() + 10.0);
      UpdateDashboard();
      return;
     }
   if(name == BTN_TP_APPLY)
     {
      string t = ObjectGetString(0, EDIT_TP, OBJPROP_TEXT);
      ApplyTpFromPanel(StringToDouble(t));
      UpdateDashboard();
      return;
     }
   if(name == BTN_SL_MINUS)
     {
      ApplySlFromPanel(MathMax(1.0, PanelSlAbs() - 100.0));
      UpdateDashboard();
      return;
     }
   if(name == BTN_SL_PLUS)
     {
      ApplySlFromPanel(PanelSlAbs() + 100.0);
      UpdateDashboard();
      return;
     }
   if(name == BTN_SL_APPLY)
     {
      string t = ObjectGetString(0, EDIT_SL, OBJPROP_TEXT);
      ApplySlFromPanel(StringToDouble(t));
      UpdateDashboard();
      return;
     }
   if(name == BTN_LOT_MINUS)
     {
      ApplyLotFromPanel(MathMax(0.0, NormalizeLot(g_InitLot - 0.01)));
      UpdateDashboard();
      return;
     }
   if(name == BTN_LOT_PLUS)
     {
      ApplyLotFromPanel(NormalizeLot(g_InitLot + 0.01));
      UpdateDashboard();
      return;
     }
   if(name == BTN_LOT_APPLY)
     {
      string t = ObjectGetString(0, EDIT_LOT, OBJPROP_TEXT);
      ApplyLotFromPanel(StringToDouble(t));
      UpdateDashboard();
      return;
     }
   if(name == BTN_SIDE_APPLY)
     {
      ApplySideTpFromPanel();
      CheckProfitExits();
      UpdateDashboard();
      ChartRedraw(0);
      return;
     }
  }

void ClearBgImage()
  {
   ObjectDelete(0, UI_BG_BMP);
  }

void ApplyBgImage()
  {
   string bmp = BgImageFile;
   StringTrimLeft(bmp);
   StringTrimRight(bmp);
   if(StringLen(bmp) <= 0)
     {
      ClearBgImage();
      return;
     }
   if(StringFind(bmp, ".bmp") < 0 && StringFind(bmp, ".BMP") < 0)
      bmp += ".bmp";

   if(ObjectFind(0, UI_BG_BMP) < 0)
      ObjectCreate(0, UI_BG_BMP, OBJ_BITMAP_LABEL, 0, 0, 0);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_XDISTANCE, 8);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_YDISTANCE, 18);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_XSIZE, UI_PANEL_W);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_YSIZE, g_ui_panel_h);
   ObjectSetString(0, UI_BG_BMP, OBJPROP_BMPFILE, bmp);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_BACK, true);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, UI_BG_BMP, OBJPROP_ZORDER, 0);
  }

void ApplyChartTheme()
  {
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_SHOW_ASK_LINE, true);
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ApplyBgImage();
   ChartRedraw(0);
   g_chart_theme_done = true;
  }

void UiSetLabel(const string name, const int x, const int y,
                const string text, const color clr, const int fontSize)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, UI_FONT);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1000);
  }

void UiSetRect(const string name, const int x, const int y, const int w, const int h,
               const color bg, const color border, const int borderW = 1)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, MathMax(1, w));
   ObjectSetInteger(0, name, OBJPROP_YSIZE, MathMax(1, h));
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, borderW);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
  }

// 只用四边细框，避免实心矩形/EDIT底板盖住文字
void UiDrawFrame4(const string t, const string b, const string l, const string r,
                  const int x, const int y, const int w, const int h,
                  const color border, const int thick = 2)
  {
   UiSetRect(t, x, y, w, thick, border, border);
   UiSetRect(b, x, y + h - thick, w, thick, border, border);
   UiSetRect(l, x, y, thick, h, border, border);
   UiSetRect(r, x + w - thick, y, thick, h, border, border);
  }

void UiDrawCardFrame(const int x, const int y, const int w, const int h, const color border)
  {
   UiDrawFrame4(UI_FRAME_T, UI_FRAME_B, UI_FRAME_L, UI_FRAME_R, x, y, w, h, border, 2);
  }

void UiDrawOuterFrame(const int x, const int y, const int w, const int h, const color border)
  {
   UiDrawFrame4(UI_OUT_T, UI_OUT_B, UI_OUT_L, UI_OUT_R, x, y, w, h, border, 2);
  }

void UiDeleteCardFrame()
  {
   ObjectDelete(0, UI_FRAME_T);
   ObjectDelete(0, UI_FRAME_B);
   ObjectDelete(0, UI_FRAME_L);
   ObjectDelete(0, UI_FRAME_R);
   ObjectDelete(0, UI_OUT_T);
   ObjectDelete(0, UI_OUT_B);
   ObjectDelete(0, UI_OUT_L);
   ObjectDelete(0, UI_OUT_R);
   ObjectDelete(0, UI_CARD_PL);
   ObjectDelete(0, UI_LIST_FILL);
  }

void DeleteDashboard()
  {
   ObjectDelete(0, UI_PANEL_BG);
   ObjectDelete(0, UI_PANEL_FILL);
   ObjectDelete(0, UI_MID_FILL);
   ObjectDelete(0, UI_LIST_FILL);
   ObjectDelete(0, UI_BG_BMP);
   UiDeleteCardFrame();
   ObjectDelete(0, UI_OUT_T);
   ObjectDelete(0, UI_OUT_B);
   ObjectDelete(0, UI_OUT_L);
   ObjectDelete(0, UI_OUT_R);
   ObjectDelete(0, UI_CARD_ACC);
   ObjectDelete(0, "XAU_UI_CARD_AI");
   ObjectDelete(0, UI_CARD_BUY);
   ObjectDelete(0, UI_CARD_SELL);
   string keys[20];
   keys[0]="0"; keys[1]="1"; keys[2]="1a"; keys[3]="1b";
   keys[4]="2"; keys[5]="2a"; keys[6]="2b"; keys[7]="2c";
   keys[8]="M0"; keys[9]="M1"; keys[10]="M2"; keys[11]="M3"; keys[12]="M4"; keys[13]="M5";
   keys[14]="ST"; keys[15]="TP_L";
   keys[16]="B0"; keys[17]="B1"; keys[18]="S0"; keys[19]="S1"; // 清旧多空标签
   for(int i = 0; i < 20; i++)
      ObjectDelete(0, UI_PREFIX + keys[i]);
   // 清掉旧面板残留
   string oldKeys[18];
   oldKeys[0]="3"; oldKeys[1]="3a"; oldKeys[2]="3b"; oldKeys[3]="3c";
   oldKeys[4]="B2"; oldKeys[5]="B3"; oldKeys[6]="B4";
   oldKeys[7]="S2"; oldKeys[8]="S3"; oldKeys[9]="S4";
   oldKeys[10]="SIDE_L"; oldKeys[11]="SIDE_L2"; oldKeys[12]="NEWS";
   oldKeys[13]="SEC1"; oldKeys[14]="1c"; oldKeys[15]="4";
   oldKeys[16]="AI0"; oldKeys[17]="AI1";
   for(int j = 0; j < 18; j++)
      ObjectDelete(0, UI_PREFIX + oldKeys[j]);
   for(int ai = 0; ai < 7; ai++)
      ObjectDelete(0, UI_PREFIX + "AI" + IntegerToString(ai));
   ObjectDelete(0, "XAU_LIQ_HI");
   ObjectDelete(0, "XAU_LIQ_LO");
   ObjectDelete(0, UI_PREFIX + "1d");
   ObjectDelete(0, UI_PREFIX + "1e");
   ObjectDelete(0, UI_PREFIX + "RSI");
   ObjectDelete(0, UI_PREFIX + "S5");
   ObjectDelete(0, UI_PREFIX + "LQ");
   ObjectDelete(0, UI_PREFIX + "LC");
   AiClearLevelObjectsSafe();
   for(int qi = 0; qi < 12; qi++)
     {
      ObjectDelete(0, UI_PREFIX + "BL" + IntegerToString(qi));
      ObjectDelete(0, UI_PREFIX + "SL" + IntegerToString(qi));
     }
   ObjectDelete(0, EDIT_TP);
   ObjectDelete(0, EDIT_SL);
   ObjectDelete(0, EDIT_LOT);
   ObjectDelete(0, EDIT_TP_BUY);
   ObjectDelete(0, EDIT_TP_SELL);
   ObjectDelete(0, BTN_TP_MINUS);
   ObjectDelete(0, BTN_TP_PLUS);
   ObjectDelete(0, BTN_TP_APPLY);
   ObjectDelete(0, BTN_SL_MINUS);
   ObjectDelete(0, BTN_SL_PLUS);
   ObjectDelete(0, BTN_SL_APPLY);
   ObjectDelete(0, BTN_LOT_MINUS);
   ObjectDelete(0, BTN_LOT_PLUS);
   ObjectDelete(0, BTN_LOT_APPLY);
   ObjectDelete(0, BTN_SIDE_APPLY);
   ObjectDelete(0, UI_PREFIX + "TP_L");
   ObjectDelete(0, UI_PREFIX + "SL_L");
   ObjectDelete(0, UI_PREFIX + "LOT_L");
   Comment("");
  }

void UpdateDashboard()
  {
   if(!g_chart_theme_done)
      ApplyChartTheme();

   ObjectDelete(0, EDIT_TP_BUY);
   ObjectDelete(0, EDIT_TP_SELL);
   ObjectDelete(0, BTN_SIDE_APPLY);
   ObjectDelete(0, UI_PREFIX + "ST");
   ObjectDelete(0, UI_PREFIX + "SIDE_L");
   ObjectDelete(0, UI_PREFIX + "SIDE_L2");
   ObjectDelete(0, UI_PREFIX + "NEWS");
   ObjectDelete(0, UI_PREFIX + "3");
   ObjectDelete(0, UI_PREFIX + "3a");
   ObjectDelete(0, UI_PREFIX + "3b");
   ObjectDelete(0, UI_PREFIX + "M0");
   ObjectDelete(0, UI_PREFIX + "M1");
   ObjectDelete(0, UI_PREFIX + "M2");
   ObjectDelete(0, UI_PREFIX + "M3");
   ObjectDelete(0, UI_PREFIX + "M4");
   ObjectDelete(0, UI_PREFIX + "M5");

   double allP  = BasketProfit(-1);
   double buyP  = BasketProfit(POSITION_TYPE_BUY, false, true);
   double sellP = BasketProfit(POSITION_TYPE_SELL, false, true);
   int buyN  = CountPositions(POSITION_TYPE_BUY, true);
   int sellN = CountPositions(POSITION_TYPE_SELL, true);
   double buyLot  = SumVolume(POSITION_TYPE_BUY, true);
   double sellLot = SumVolume(POSITION_TYPE_SELL, true);
   double buyAvg  = AvgOpenPrice(POSITION_TYPE_BUY, true);
   double sellAvg = AvgOpenPrice(POSITION_TYPE_SELL, true);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double dayPnL  = DayPnL_Total();
   double dayWin = 0.0, dayLoss = 0.0;
   double dayClosed = DayClosedPnL(dayWin, dayLoss);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   PanelRsiValue();
   string rsiTxt = (g_panel_rsi > 0.0 ? StringFormat("RSI %.1f", g_panel_rsi) : "RSI -");
   color rsiCol = PanelRsiColor();
   double nextBuyStep  = CurrentGridStepUSD(MathMax(1, buyN));
   double nextSellStep = CurrentGridStepUSD(MathMax(1, sellN));

   string status = "运行中";
   if(BotFullyPaused())
      status = "已暂停";
   else if(g_sl_pause_until > 0 && TimeCurrent() < g_sl_pause_until)
     {
      int left = (int)(g_sl_pause_until - TimeCurrent());
      status = StringFormat("止损冷却%d分%d秒", left / 60, left % 60);
     }
   else if(NewsCalendar_IsFrozen())
      status = StringFormat("新闻清仓禁开|%s", g_news.event_name);
   else if(!InOpenSession())
      status = "AI时段外可手开 " + OpenSessionText();

   color colAll = (allP >= 0.0 ? UI_COL_GREEN : UI_COL_RED);
   color colDay = (dayClosed >= 0.0 ? UI_COL_GREEN : UI_COL_RED);
   color colBuy = (buyP >= 0.0 ? UI_COL_GREEN : UI_COL_RED);
   color colSell = (sellP >= 0.0 ? UI_COL_GREEN : UI_COL_RED);
   color colMuted = UI_COL_MUTED;
   color colText  = UI_COL_TEXT;

   ObjectDelete(0, UI_PANEL_BG);
   ObjectDelete(0, UI_LIST_FILL);
   ObjectDelete(0, UI_CARD_ACC);
   ObjectDelete(0, "XAU_UI_CARD_AI");
   UiDeleteCardFrame();

   string bmp = BgImageFile;
   StringTrimLeft(bmp);
   StringTrimRight(bmp);
   if(StringLen(bmp) > 0)
      ApplyBgImage();
   else
      ClearBgImage();

#ifdef EA_PANEL_WIN
   // 不铺实心底色。Windows 上实心矩形会盖住后画的字和按钮
   ObjectDelete(0, UI_PANEL_FILL);
   ObjectDelete(0, UI_MID_FILL);
   const int ox = 8, oy = 8;
   const int ax = ox + UI_PANEL_W / 2;
   const int bx = ox + 12;
   const int sx = ax;
   const int row = 34;
   const int listY = oy + row * 7;
   const int listLineH = row;
   g_ui_btn_y = listY + row + UI_POS_LIST_MAX * row + row + 6;
   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   const int btnBlock = UI_BTN_H * 3 + UI_BTN_GAP * 2 + 8;
   if(chartH > btnBlock + 40 && g_ui_btn_y + btnBlock > chartH - 2)
      g_ui_btn_y = chartH - 2 - btnBlock;
   if(g_ui_btn_y < oy + row * 4)
      g_ui_btn_y = oy + row * 4;
   g_ui_panel_h = (g_ui_btn_y + btnBlock) - oy;
   UiDrawOuterFrame(ox, oy, UI_PANEL_W, g_ui_panel_h, UI_COL_BORDER);
   ObjectDelete(0, UI_PREFIX + "1");
   ObjectDelete(0, UI_PREFIX + "1c");
   ObjectDelete(0, UI_PREFIX + "1d");
   ObjectDelete(0, UI_PREFIX + "1e");
   ObjectDelete(0, UI_PREFIX + "2");
   ObjectDelete(0, UI_PREFIX + "B1");
   ObjectDelete(0, UI_PREFIX + "B2");
   ObjectDelete(0, UI_PREFIX + "B3");
   ObjectDelete(0, UI_PREFIX + "B4");
   ObjectDelete(0, UI_PREFIX + "S1");
   ObjectDelete(0, UI_PREFIX + "S2");
   ObjectDelete(0, UI_PREFIX + "S3");
   ObjectDelete(0, UI_PREFIX + "S4");
   ObjectDelete(0, UI_PREFIX + "S5");
   ObjectDelete(0, UI_PREFIX + "SEC1");
   UiSetLabel(UI_PREFIX + "0", bx, oy + 2,
              StringFormat("DeepSeek_EA %s%s",
                           IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)),
                           (!UseSharedConfig ? "" : (SharedConfigMaster ? " 主" : " 从"))),
              UI_COL_TITLE, UI_TITLE_SIZE);
   ObjectDelete(0, UI_PREFIX + "2c");
   UiSetLabel(UI_PREFIX + "RSI", ox + UI_PANEL_W - 130, oy + 2, rsiTxt, rsiCol, UI_TITLE_SIZE);
   UiSetLabel(UI_PREFIX + "1a", bx, oy + row, StringFormat("浮 %+.0f", allP), colAll, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "1b", bx, oy + row * 2, StringFormat("今日 %+.0f", dayClosed), colDay, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "2a", ax, oy + row, StringFormat("余 %.0f", bal), colText, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "2b", ax, oy + row * 2, StringFormat("净 %.0f", eq), colText, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "B0", bx, oy + row * 3,
              StringFormat("多%d %.2f手 %+.0f", buyN, buyLot, buyP), colBuy, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "S0", sx, oy + row * 3,
              StringFormat("空%d %.2f手 %+.0f", sellN, sellLot, sellP), colSell, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "RULE", bx, oy + row * 4, WinConfidenceLine(), UI_COL_TITLE, UI_FONT_SIZE);
   AiDrawPanelLines(bx, oy + row * 5, colMuted);
   UiSetLabel(UI_PREFIX + "LQ", bx, listY, "队列#1最早", colMuted, UI_SMALL_SIZE);
#else
   const int ox = 10, oy = 20;
   const int y1 = oy + 46;
   const int topH = 7 * UI_ROW + 16;
   const int midY = y1 + topH;
   const int aiRows = AiPanelExtraRows();
   const int midH = 9 * UI_ROW + 16 + aiRows * UI_ROW;
   const int midW = UI_PANEL_W - 28;
   const int listY = midY + midH + 12;
   const int listLineH = UI_ROW;
   const int listH = UI_ROW + listLineH * UI_POS_LIST_MAX + UI_ROW + 8;
   g_ui_btn_y = listY + listH + 14;
   g_ui_panel_h = (g_ui_btn_y + UI_BTN_H * 3 + UI_BTN_GAP * 2 + 24) - oy;
   if(g_ui_panel_h < UI_PANEL_H_MIN)
      g_ui_panel_h = UI_PANEL_H_MIN;
   UiDrawOuterFrame(ox, oy, UI_PANEL_W, g_ui_panel_h, UI_COL_BORDER);
   UiDrawCardFrame(ox + 12, midY, midW, midH, UI_COL_BORDER);
   UiSetLabel(UI_PREFIX + "0", ox + 16, oy + 10,
              StringFormat("DeepSeek_EA  %s%s",
                           IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)),
                           (!UseSharedConfig ? "" : (SharedConfigMaster ? " ·主号" : " ·从号"))),
              UI_COL_TITLE, UI_TITLE_SIZE);
   ObjectDelete(0, UI_PREFIX + "2c");
   UiSetLabel(UI_PREFIX + "RSI", ox + UI_PANEL_W - 170, oy + 8, rsiTxt, rsiCol, UI_TITLE_SIZE);
   const int leftX = ox + 24;
   const int rightX = ox + 480;
   const int ax = rightX;
   UiSetLabel(UI_PREFIX + "1", leftX, y1, "浮动盈亏", colMuted, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "1a", leftX, y1 + UI_ROW, DoubleToString(allP, 2), colAll, UI_BIG_SIZE);
   UiSetLabel(UI_PREFIX + "1c", leftX, y1 + 2 * UI_ROW + 10, "今日平仓(盈亏已轧差)", UI_COL_TITLE, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "1b", leftX, y1 + 3 * UI_ROW + 10, StringFormat("%+.2f", dayClosed), colDay, UI_BIG_SIZE - 2);
   UiSetLabel(UI_PREFIX + "1d", leftX, y1 + 5 * UI_ROW,
              StringFormat("盈%+.0f  亏%+.0f", dayWin, dayLoss), colMuted, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "1e", leftX, y1 + 6 * UI_ROW,
              StringFormat("净值日 %+.2f · %s", dayPnL, status), colMuted, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "2", ax, y1, "账户", colMuted, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "2a", ax, y1 + UI_ROW, StringFormat("余额 %.2f", bal), colText, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "2b", ax, y1 + 2 * UI_ROW, StringFormat("净值 %.2f", eq), colText, UI_FONT_SIZE);
   const int bx = leftX;
   const int sx = rightX;
   UiSetLabel(UI_PREFIX + "B0", bx, midY + 10,
              StringFormat("多  %d/%d层", buyN, g_MaxLayers), UI_COL_GREEN, UI_FONT_SIZE + 1);
   UiSetLabel(UI_PREFIX + "B1", bx, midY + 10 + UI_ROW,
              StringFormat("%d单  %.2f手  %+.2f", buyN, buyLot, buyP), colBuy, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "B2", bx, midY + 10 + 2 * UI_ROW,
              StringFormat("均价 %s", (buyN > 0 ? DoubleToString(buyAvg, _Digits) : "-")), colText, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "B3", bx, midY + 10 + 3 * UI_ROW,
              StringFormat("现价 %s  间距%.1f", DoubleToString(ask, _Digits), nextBuyStep), colMuted, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "B4", bx, midY + 10 + 4 * UI_ROW,
              StringFormat("多篮止盈 %+.0f/%.0f", buyP, g_BasketTP),
              (buyP >= g_BasketTP && buyN > 0 ? UI_COL_GREEN : colMuted), UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "S0", sx, midY + 10,
              StringFormat("空  %d/%d层", sellN, g_MaxLayers), UI_COL_RED, UI_FONT_SIZE + 1);
   UiSetLabel(UI_PREFIX + "S1", sx, midY + 10 + UI_ROW,
              StringFormat("%d单  %.2f手  %+.2f", sellN, sellLot, sellP), colSell, UI_FONT_SIZE);
   UiSetLabel(UI_PREFIX + "S2", sx, midY + 10 + 2 * UI_ROW,
              StringFormat("均价 %s", (sellN > 0 ? DoubleToString(sellAvg, _Digits) : "-")), colText, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "S3", sx, midY + 10 + 3 * UI_ROW,
              StringFormat("现价 %s  间距%.1f", DoubleToString(bid, _Digits), nextSellStep), colMuted, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "S4", sx, midY + 10 + 4 * UI_ROW,
              StringFormat("空篮止盈 %+.0f/%.0f", sellP, g_BasketTP),
              (sellP >= g_BasketTP && sellN > 0 ? UI_COL_GREEN : UI_COL_RED), UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "S5", sx, midY + 10 + 5 * UI_ROW,
              StringFormat("总止损 %.0f", g_BasketSL_Money),
              (g_BasketSL_Money < 0.0 ? UI_COL_RED : colMuted), UI_SMALL_SIZE);
   bool aiOff = (AiDrivesEntry() && !AiBridgeOn());
   string hint = BotFullyPaused() ? "已暂停开仓"
                 : (aiOff ? "AI未开，不下单"
                    : (!IsCmdMaster()
                       ? StringFormat("从号跟随·止盈%.0f 止损%.0f·%s",
                                      g_BasketTP, g_BasketSL_Money, OpenSessionText())
                       : (AiDrivesEntry()
                          ? StringFormat("趋势追完按点数做震荡·止盈%.0f 止损%.0f·%s",
                                         g_BasketTP, g_BasketSL_Money, OpenSessionText())
                          : StringFormat("手开首仓+间距加仓·止盈%.0f·%s",
                                         g_BasketTP, OpenSessionText()))));
   string judgeLine = DeepSeekJudgeLine();
   UiSetLabel(UI_PREFIX + "SEC1", bx, midY + 10 + 6 * UI_ROW, hint, colMuted, UI_SMALL_SIZE);
   UiSetLabel(UI_PREFIX + "RULE", bx, midY + 10 + 7 * UI_ROW, judgeLine,
              (aiOff ? UI_COL_RED : UI_COL_TITLE), UI_FONT_SIZE);
   AiDrawPanelLines(bx, midY + 10 + 8 * UI_ROW, colMuted);
   UiSetLabel(UI_PREFIX + "LQ", bx, listY, "队列 #1=最早一单(平完后自动上移)", colMuted, UI_SMALL_SIZE);
#endif
   for(int oldi = UI_POS_LIST_MAX; oldi < 12; oldi++)
     {
      ObjectDelete(0, UI_PREFIX + "BL" + IntegerToString(oldi));
      ObjectDelete(0, UI_PREFIX + "SL" + IntegerToString(oldi));
     }
   ulong buyTk[], sellTk[];
   int buyTotal  = CollectGridTicketsOldestFirst(POSITION_TYPE_BUY, buyTk, UI_POS_LIST_MAX);
   int sellTotal = CollectGridTicketsOldestFirst(POSITION_TYPE_SELL, sellTk, UI_POS_LIST_MAX);
   int buyShow  = ArraySize(buyTk);
   int sellShow = ArraySize(sellTk);
   for(int li = 0; li < UI_POS_LIST_MAX; li++)
     {
      string bName = UI_PREFIX + "BL" + IntegerToString(li);
      string sName = UI_PREFIX + "SL" + IntegerToString(li);
      int ly = listY + UI_ROW + li * listLineH;
      if(li < buyShow && PositionSelectByTicket(buyTk[li]))
        {
         double v = PositionGetDouble(POSITION_VOLUME);
         double p = PositionGetDouble(POSITION_PRICE_OPEN);
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         string who = PositionGetString(POSITION_COMMENT);
         if(StringFind(who, "AI下单") >= 0 || StringFind(who, "机器人") >= 0) who = "AI下单 ";
         else if(StringFind(who, "专家") >= 0 || StringFind(who, "人工") >= 0) who = "专家 ";
         else who = "";
         string bt = StringFormat("#%d %s%.2f手 @%s %+.1f", li + 1, who, v, DoubleToString(p, _Digits), pf);
         if(li == UI_POS_LIST_MAX - 1 && buyTotal > buyShow)
            bt = StringFormat("#%d…共%d单 %+.1f", li + 1, buyTotal, pf);
         UiSetLabel(bName, bx, ly, bt, (li == 0 ? UI_COL_GREEN : colMuted), UI_SMALL_SIZE);
        }
      else if(li == 0 && buyTotal <= 0)
         UiSetLabel(bName, bx, ly, "多#1 无仓", colMuted, UI_SMALL_SIZE);
      else
         ObjectDelete(0, bName);

      if(li < sellShow && PositionSelectByTicket(sellTk[li]))
        {
         double v = PositionGetDouble(POSITION_VOLUME);
         double p = PositionGetDouble(POSITION_PRICE_OPEN);
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         string who = PositionGetString(POSITION_COMMENT);
         if(StringFind(who, "AI下单") >= 0 || StringFind(who, "机器人") >= 0) who = "AI下单 ";
         else if(StringFind(who, "专家") >= 0 || StringFind(who, "人工") >= 0) who = "专家 ";
         else who = "";
         string st = StringFormat("#%d %s%.2f手 @%s %+.1f", li + 1, who, v, DoubleToString(p, _Digits), pf);
         if(li == UI_POS_LIST_MAX - 1 && sellTotal > sellShow)
            st = StringFormat("#%d…共%d单 %+.1f", li + 1, sellTotal, pf);
         UiSetLabel(sName, sx, ly, st, (li == 0 ? UI_COL_RED : colMuted), UI_SMALL_SIZE);
        }
      else if(li == 0 && sellTotal <= 0)
         UiSetLabel(sName, sx, ly, "空#1 无仓", colMuted, UI_SMALL_SIZE);
      else
         ObjectDelete(0, sName);
     }
   UiSetLabel(UI_PREFIX + "LC", bx, listY + UI_ROW + UI_POS_LIST_MAX * listLineH,
              g_last_close_info, g_last_close_col, UI_SMALL_SIZE);
   // 删除旧版可能残留的叠字标签
   ObjectDelete(0, UI_PREFIX + "2c_old");

   CreateParamControls(ox + 10, g_ui_btn_y);
   RefreshPanelButtons();
   ChartRedraw(0);
  }

string TradeFailText()
  {
   uint rc = trade.ResultRetcode();
   string cn = trade.ResultRetcodeDescription();
   if(rc == TRADE_RETCODE_CLIENT_DISABLES_AT)
      cn = "自动交易没开，点工具栏的算法交易";
   else if(rc == TRADE_RETCODE_SERVER_DISABLES_AT)
      cn = "服务器禁止自动交易";
   else if(rc == TRADE_RETCODE_MARKET_CLOSED)
      cn = "市场已休市";
   else if(rc == TRADE_RETCODE_NO_MONEY)
      cn = "保证金不够";
   else if(rc == TRADE_RETCODE_TRADE_DISABLED)
      cn = "这个品种禁止交易";
   else if(rc == TRADE_RETCODE_INVALID_VOLUME)
      cn = "手数不合法";
   else if(rc == TRADE_RETCODE_INVALID_STOPS)
      cn = "止损止盈距离不够";
   else if(rc == TRADE_RETCODE_TOO_MANY_REQUESTS)
      cn = "下单太频繁，稍后再试";
   else if(rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_PRICE_OFF)
      cn = "价格变了，没成交";
   else if(rc == TRADE_RETCODE_REJECT)
      cn = "服务器拒绝";
   else if(rc == TRADE_RETCODE_CONNECTION)
      cn = "连接中断";
   else if(rc == TRADE_RETCODE_INVALID_FILL)
      cn = "成交模式不对";
   return StringFormat("%s (代码%u)", cn, rc);
  }

bool OpenMarket(const ENUM_ORDER_TYPE type, const double lot, const string tag,
                const double sl_price = 0.0, const double tp_price = 0.0)
  {
   bool manual = (StringFind(tag, "专家") >= 0 || StringFind(tag, "人工") >= 0);
   string hand = (manual ? "手动" : "自动");
   if(!CanOpenNewOrders())
     {
      g_last_open_fail = "止损冷却中";
      PrintFormat("%s开仓失败: %s", hand, g_last_open_fail);
      return false;
     }
   if(NewsCalendar_IsFrozen())
     {
      g_last_open_fail = "新闻窗口不开新仓: " + g_news.event_name;
      static datetime lastNewsBlock = 0;
      if(TimeCurrent() - lastNewsBlock >= 60)
        {
         PrintFormat("%s开仓失败: %s", hand, g_last_open_fail);
         lastNewsBlock = TimeCurrent();
        }
      return false;
     }
   if(!SpreadOK())
     {
      g_last_open_fail = "点差过大";
      PrintFormat("%s开仓失败: %s", hand, g_last_open_fail);
      return false;
     }
   trade.SetExpertMagicNumber(MagicBase);
   trade.SetDeviationInPoints(30);
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string cmt = tag;
   if(StringFind(tag, "专家") < 0 && StringFind(tag, "AI下单") < 0 &&
      StringFind(tag, "人工") < 0 && StringFind(tag, "机器人") < 0)
      cmt = OrderCommentText + "|" + tag;
   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, price, sl_price, tp_price, cmt)
             : trade.Sell(lot, _Symbol, price, sl_price, tp_price, cmt);
   if(ok)
     {
      datetime now = TimeCurrent();
      g_lastAddTime = now;
      if(type == ORDER_TYPE_BUY)
         g_lastAddBuy = now;
      else
         g_lastAddSell = now;
#ifdef EA_BUILD_WITH_AI
      if(AiDrivesEntry())
        {
         if(CommentIsManual(cmt))
           {
            g_manual_hold = true;
            g_ai_entry_bar = 0;
           }
         else
           {
            g_manual_hold = false;
            datetime barNow = iTime(_Symbol, PERIOD_M5, 0);
            if(barNow > 0)
               g_ai_entry_bar = barNow;
           }
        }
#endif
     }
   else
     {
      g_last_open_fail = TradeFailText();
      bool manualFail = (StringFind(cmt, "专家") >= 0 || StringFind(cmt, "人工") >= 0);
      PrintFormat("%s开仓失败: %s", (manualFail ? "手动" : "自动"), g_last_open_fail);
     }
   return ok;
  }

bool OpenFirstIfEmpty(const int posType, const ENUM_ORDER_TYPE orderType, const string tag)
  {
   if(CountPositions(posType, true) > 0)
      return false;
   if(g_InitLot <= 0.0 || g_MaxLayers <= 0)
      return false;
   if(posType == POSITION_TYPE_BUY && g_pause_buy)
      return false;
   if(posType == POSITION_TYPE_SELL && g_pause_sell)
      return false;
   return OpenMarket(orderType, NormalizeLot(g_InitLot), tag);
  }

// 固定双边：返回 2。旧代码若当 0/1 用，勿再当单边开关
int ResolvedMartinDirection()
  {
   return 2;
  }

datetime LastAddTimeOf(const int posType)
  {
   datetime t = (posType == POSITION_TYPE_BUY ? g_lastAddBuy : g_lastAddSell);
   // 回退到该边最新持仓时间，防止重挂后内存冷却丢失而连开
   datetime posT = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicBase)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
      if(pt > posT)
         posT = pt;
     }
   return (posT > t ? posT : t);
  }

// 有新鲜的 DeepSeek 方向时，只允许顺着这个方向加仓。没信号时沿用原间距逻辑。
bool AiAllowsAdd(const int posType)
  {
#ifdef EA_BUILD_WITH_AI
   if(!UseExternalAI || !AiAutoOpen)
      return true;
   if(!g_ai_judge.from_external_ai)
      return true;
   if(g_ai_judge.freeze_orders)
      return false;
   if(g_ai_judge.confidence < 72.0)
      return false;
   if(posType == POSITION_TYPE_BUY)
      return (g_ai_judge.direction == TREND_UP);
   if(posType == POSITION_TYPE_SELL)
      return (g_ai_judge.direction == TREND_DOWN);
   return false;
#else
   return true;
#endif
  }

bool PositionNeedsBarSettle()
  {
   if(PositionGetInteger(POSITION_MAGIC) != MagicBase)
      return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   string cmt = PositionGetString(POSITION_COMMENT);
   if(CommentIsManual(cmt))
      return false;
   if(!CommentIsAi(cmt) && g_manual_hold)
      return false;
   return true;
  }

int CountAiSettlePositions()
  {
   int n = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionNeedsBarSettle())
         n++;
     }
   return n;
  }

datetime AiPositionEntryBar()
  {
   datetime bar = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionNeedsBarSettle())
         continue;
      datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
      int shift = iBarShift(_Symbol, PERIOD_M5, pt, false);
      if(shift < 0)
         continue;
      datetime b = iTime(_Symbol, PERIOD_M5, shift);
      if(b > bar)
         bar = b;
     }
   return bar;
  }

// 不再按单根 M5 结束平仓。AI 和人工都等篮子止盈或止损。
bool SettleAiSingleBar()
  {
   if(CountPositions() <= 0)
     {
      g_ai_entry_bar = 0;
      g_manual_hold = false;
     }
   return false;
  }

// 每 40 秒看一次。方向只认 DeepSeek，EA 只负责开仓。
bool ManageAiFirstOpen()
  {
#ifdef EA_BUILD_WITH_AI
   if(!AiDrivesEntry() || !IsCmdMaster())
      return false;
   if(!InOpenSession())
      return false;

   if(g_range_trade && g_box_hi > g_box_lo)
     {
      double mid = (g_box_hi + g_box_lo) / 2.0;
      if(CountPositions() <= 0)
         g_range_trade = false;
      else if(CountPositions(POSITION_TYPE_BUY, true) > 0 &&
              SymbolInfoDouble(_Symbol, SYMBOL_BID) >= mid)
        {
         PrintFormat("震荡回到中线，平多");
         g_range_trade = false;
         MasterBroadcastCmd("CLOSE_BUY");
         return true;
        }
      else if(CountPositions(POSITION_TYPE_SELL, true) > 0 &&
              SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= mid)
        {
         PrintFormat("震荡回到中线，平空");
         g_range_trade = false;
         MasterBroadcastCmd("CLOSE_SELL");
         return true;
        }
     }

   static datetime s_next_think = 0;
   if(TimeCurrent() < s_next_think)
      return false;
   s_next_think = TimeCurrent() + 40;

   // 关掉 AI 窗口后不再自动开仓。面板上的专家手动单不走这里。
   if(!AiBridgeOn())
     {
      Print("AI窗口没开，不下单");
      return false;
     }
   int held = DeepSeekOpenSide();
   int run = M5Leg();
   // 信心到 72，而且五分钟结构和已经确认的方向一致，才算趋势。AI 刚改口不算行情转换。
   bool trend = (g_ai_judge.confidence >= 72.0 && held != 0 && run == held);
   int side = 0;
   bool asRange = false;
   if(g_ai_judge.confidence >= 72.0 && held != 0 && run != 0 && run != held)
     {
      Print("反向未确认，行情不转换");
      return false;
     }
   if(trend)
     {
      int want = run;
      if(want > 0 && CountPositions(POSITION_TYPE_SELL, true) > 0)
        {
         Print("趋势做多，平掉反向空单，不等止损");
         MasterBroadcastCmd("CLOSE_SELL");
         return true;
        }
      if(want < 0 && CountPositions(POSITION_TYPE_BUY, true) > 0)
        {
         Print("趋势做空，平掉反向多单，不等止损");
         MasterBroadcastCmd("CLOSE_BUY");
         return true;
        }
     }
   if(g_ai_judge.confidence < 50.0)
     {
      Print("信心不到50，不开仓");
      return false;
     }
   int brk = SimilarBaseBreak();
   if(brk != 0 && g_ai_judge.confidence >= 72.0 && held != 0 && brk != held)
     {
      Print("反向未确认，行情不转换");
      return false;
     }
   if(brk != 0)
     {
      side = brk;
      asRange = false;
     }
   else
     {
      if(LongLineWatch())
        {
         Print("长线，先观望，这根不开");
         return false;
        }
      if(trend)
        {
         int want = run;
         if(!TrendDipReady(want))
            want = 0;
         side = want;
        }
      else if(g_ai_judge.confidence >= 50.0 && g_ai_judge.confidence < 72.0)
        {
         int chop = ChopSide();
         if(chop != 0)
           {
            side = chop;
            asRange = true;
           }
        }
     }
   if(side == 0)
     {
      g_entry_arm_side = 0;
      g_entry_arm_hits = 0;
      return false;
     }
   if(side != g_entry_arm_side)
     {
      g_entry_arm_side = side;
      g_entry_arm_hits = 1;
      Print("先看一会回调，不急着下");
      return false;
     }
   if(g_entry_arm_hits < 2)
     {
      g_entry_arm_hits = 2;
      Print("回调看过了，可以下");
     }
   if(side < 0 && NearSupport())
     {
      Print("支撑上先看回调，这根先不空");
      return false;
     }
   if(side > 0 && NearResist())
     {
      Print("压力上先看回调，这根先不多");
      return false;
     }
   if(CountPositions(POSITION_TYPE_BUY, true) > 0 ||
      CountPositions(POSITION_TYPE_SELL, true) > 0)
      return false;
   if(BotFullyPaused() || !CanOpenNewOrders())
      return false;
   if(g_InitLot <= 0.0 || g_MaxLayers <= 0)
      return false;

   string cmd = (side > 0 ? "AI_BUY" : "AI_SELL");
   PrintFormat("40秒入场: %s%s 信心%.0f %s | 止盈%.0f 止损%.0f 时段%s",
               (brk != 0 ? "前K差不多" : (asRange ? StringFormat("震荡%.0f点", g_chop_pts) : (trend ? "趋势" : "震荡"))),
               (side > 0 ? "做多" : "做空"),
               g_ai_judge.confidence, g_ai_judge.reason,
               g_BasketTP, g_BasketSL_Money, OpenSessionText());
   bool opened = MasterBroadcastCmd(cmd);
   if(opened)
     {
      double px = (side > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
      string whyOpen = (brk != 0 ? "前K差不多就进" : (trend ? "趋势回落就进" : "区间边缘就进"));
      if(side < 0 && g_ai_judge.support1 > 0.0 && px <= g_ai_judge.support1 + 2.0)
         whyOpen = "贴着支撑开空";
      if(side > 0 && g_ai_judge.resist1 > 0.0 && px >= g_ai_judge.resist1 - 2.0)
         whyOpen = "贴着压力开多";
      int eh = FileOpen("ai\\last_entry.txt", FILE_WRITE|FILE_TXT|FILE_UNICODE|FILE_COMMON);
      if(eh != INVALID_HANDLE)
        {
         FileWriteString(eh, StringFormat("SIDE=%s\nPRICE=%.2f\nSUP=%.2f\nRES=%.2f\nWHY=%s\n",
                         (side > 0 ? "BUY" : "SELL"), px, g_ai_judge.support1, g_ai_judge.resist1, whyOpen));
         FileClose(eh);
        }
     }
   if(opened && asRange)
     {
      g_range_trade = true;
      g_box_hi = g_chop_hi;
      g_box_lo = g_chop_lo;
     }
   else if(opened)
      g_range_trade = false;
   return opened;
#else
   return false;
#endif
  }

// 已有仓后：仅逆势间距加仓（该边浮亏才加），主号发令从号跟随
bool ManageMartinSide(const int posType, const ENUM_ORDER_TYPE orderType)
  {
   if(!IsCmdMaster())
      return false;
   if(BotFullyPaused() || !CanOpenNewOrders())
      return false;
   if(posType == POSITION_TYPE_BUY && g_pause_buy)
      return false;
   if(posType == POSITION_TYPE_SELL && g_pause_sell)
      return false;

   int layers = CountPositions(posType, true);
   if(layers <= 0 || layers >= g_MaxLayers)
      return false;

   datetime lastAdd = LastAddTimeOf(posType);
   if(g_AddCooldownSec > 0 && lastAdd > 0 &&
      TimeCurrent() - lastAdd < g_AddCooldownSec)
      return false;

   // 该边浮盈不加，只逆势补
   if(BasketProfit(posType, false, true) >= 0.0)
      return false;

   bool found = false;
   double lastPx = LastOpenPrice(posType, found, true);
   if(!found)
      return false;

   double step = CurrentGridStepUSD(layers);
   // 间距=0：默认不加仓（避免 step=0 时价差恒成立疯狂连开）
   if(step <= 0.0)
      return false;
   if(g_InitLot <= 0.0 || g_MaxLayers <= 0)
      return false;
   if(!AiAllowsAdd(posType))
      return false;
   if(posType == POSITION_TYPE_SELL && NearSupport())
      return false;
   if(posType == POSITION_TYPE_BUY && NearResist())
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool hit = false;
   if(posType == POSITION_TYPE_BUY)
      hit = (bid <= lastPx - step);
   else
      hit = (ask >= lastPx + step);
   if(!hit)
      return false;

   PrintFormat("间距加仓: %s 层%d→%d 距%.2f 需%.2f",
               (posType == POSITION_TYPE_BUY ? "多" : "空"),
               layers, layers + 1,
               (posType == POSITION_TYPE_BUY ? (lastPx - bid) : (ask - lastPx)),
               step);
   // 仅本地成交成功才算加仓成功（内部已先开后广播）
   return MasterBroadcastCmd(posType == POSITION_TYPE_BUY ? "AI_BUY" : "AI_SELL");
  }

void RunGridMode()
  {
   CheckProfitExits();
   // 从号只跟随。主号每 40 秒按 DeepSeek 的方向开仓，止盈止损才平。
   if(!IsCmdMaster())
      return;
   if(AiDrivesEntry())
     {
      if(SettleAiSingleBar())
         return;
      ManageAiFirstOpen();
      return;
     }
   if(ManageMartinSide(POSITION_TYPE_BUY, ORDER_TYPE_BUY))
      return;
   ManageMartinSide(POSITION_TYPE_SELL, ORDER_TYPE_SELL);
  }

//+------------------------------------------------------------------+
void AttachShortMAs();
void DetachShortMAs();
void AttachTrendOsc();
void DetachTrendOsc();
void EnsureOscHandles();
void DrawAvgPriceLines();

int OnInit()
  {
   // InitLot=0 允许挂载（表示禁止开仓）；负手数/倍率非法才拒载
   if(InitLot < 0.0 || MartinMult < 1.0)
      return INIT_PARAMETERS_INCORRECT;

   trade.SetExpertMagicNumber(MagicBase);

   g_sl_pause_until = 0;
   g_pause_buy = false;
   g_pause_sell = false;
   g_news_was_frozen = false;
   g_hedge_against = -1;
   g_chart_theme_done = false;
   g_ui_controls_ready = false;
   g_tp_edit_focus = false;
   g_side_edit_focus = false;
   g_spread_window_start = 0;
   g_spread_max_2h_pts = 0;
   AiOnInitReset();
   g_lastAddBuy = 0;
   g_lastAddSell = 0;
   g_MartinDirection = 2;

   // 默认参数 → 共享文件（无则创建；有则加载）
   CfgInitShared();
   g_MartinDirection = 2;
   ResetDayBaseline();
   // 重挂后从持仓恢复加仓冷却，避免 lastAdd=0 时无冷却连加十几单
   SyncLastAddFromPositions();
   g_manual_hold = (CountAiSettlePositions() <= 0 && CountPositions() > 0);

   // 启动时跳到队列末尾，避免重启把历史指令重放一遍
   g_cmd_watermark_ready = false;
   g_applied_cmd_id = 0;
   CmdFollowAlignWatermark(true);

   // 主号重挂后本地暂停已清空：立刻写共享+发 RESUME，避免从号仍停在旧暂停
   if(UseSharedConfig && SharedConfigMaster)
     {
      g_pause_buy = false;
      g_pause_sell = false;
      CfgWriteShared();
      MasterBroadcastCmd("RESUME");
     }
   else if(UseSharedConfig && !SharedConfigMaster)
     {
      // 从号再读一次，吃到主号最新 Paused
      CfgReadShared();
     }

   ApplyChartTheme();
   DeletePanelButtons();
   DeleteDashboard();
   g_ui_controls_ready = false;
   RefreshPanelButtons();
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
   UpdateDashboard();
   NewsCalendar_Refresh(g_UseNewsFilter, g_NewsBeforeMin, g_NewsAfterMin, NewsRefreshSec);
   g_sl_edit_focus = false;
   g_lot_edit_focus = false;
   AiPrintBootBanner();
   DetachTrendOsc();
   EnsureOscHandles();
   AttachShortMAs();
#ifdef EA_BUILD_WITH_AI
   EventSetTimer(MathMax(3, AiSnapshotSec));
   AiRefreshAssist();
#endif
   return INIT_SUCCEEDED;
  }

void AttachShortMAs()
  {
   ChartIndicatorDelete(0, 0, "短线均线");
   if(g_chart_short_ma != INVALID_HANDLE)
     {
      IndicatorRelease(g_chart_short_ma);
      g_chart_short_ma = INVALID_HANDLE;
     }
   g_chart_short_ma = iCustom(_Symbol, PERIOD_CURRENT, "XAU_ShortMA");
   if(g_chart_short_ma == INVALID_HANDLE)
     {
      Print("短线均线未挂上：把 XAU_ShortMA.ex5 放到 MQL5\\Indicators 后重新挂 EA");
      return;
     }
   if(!ChartIndicatorAdd(0, 0, g_chart_short_ma))
      PrintFormat("短线均线挂到图表失败 err=%d", GetLastError());
  }

void DetachShortMAs()
  {
   ChartIndicatorDelete(0, 0, "短线均线");
   if(g_chart_short_ma != INVALID_HANDLE)
     {
      IndicatorRelease(g_chart_short_ma);
      g_chart_short_ma = INVALID_HANDLE;
     }
  }

bool AddSubwindowIndicator(const int handle, const string title)
  {
   if(handle == INVALID_HANDLE)
     {
      Print(title + " 创建失败");
      return false;
     }
   ResetLastError();
   int sub = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   if(ChartIndicatorAdd(0, sub, handle))
     {
      Print(title + " 已挂在K线下方");
      ChartRedraw(0);
      return true;
     }
   int err = GetLastError();
   PrintFormat("%s 未挂上 err=%d", title, err);
   return false;
  }

void ReleaseHandle(int &handle)
  {
   if(handle == INVALID_HANDLE)
      return;
   IndicatorRelease(handle);
   handle = INVALID_HANDLE;
  }

void EnsureOscHandles()
  {
   ENUM_TIMEFRAMES tf = PERIOD_M5;
   if(g_chart_macd == INVALID_HANDLE)
      g_chart_macd = iMACD(_Symbol, tf, 12, 26, 9, PRICE_CLOSE);
   if(g_chart_adx == INVALID_HANDLE)
      g_chart_adx = iADX(_Symbol, tf, 14);
   if(g_chart_rsi == INVALID_HANDLE)
      g_chart_rsi = iRSI(_Symbol, tf, 14, PRICE_CLOSE);
   if(g_chart_stoch == INVALID_HANDLE)
      g_chart_stoch = iStochastic(_Symbol, tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
  }

void DrawAvgPriceLines()
  {
   double buyAvg = AvgOpenPrice(POSITION_TYPE_BUY, true);
   double sellAvg = AvgOpenPrice(POSITION_TYPE_SELL, true);
   if(buyAvg > 0.0)
     {
      AutoJudge_DrawHLine("XAU_AVG_BUY", buyAvg, clrLime, "多均价");
      ObjectSetInteger(0, "XAU_AVG_BUY", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "XAU_AVG_BUY", OBJPROP_STYLE, STYLE_SOLID);
     }
   else
      ObjectDelete(0, "XAU_AVG_BUY");
   if(sellAvg > 0.0)
     {
      AutoJudge_DrawHLine("XAU_AVG_SELL", sellAvg, clrRed, "空均价");
      ObjectSetInteger(0, "XAU_AVG_SELL", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "XAU_AVG_SELL", OBJPROP_STYLE, STYLE_SOLID);
     }
   else
      ObjectDelete(0, "XAU_AVG_SELL");
   double mean3 = M5Mean3();
   if(mean3 > 0.0)
     {
      AutoJudge_DrawHLine("XAU_MEAN3", mean3, clrWhite, "三根均价");
      ObjectSetInteger(0, "XAU_MEAN3", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "XAU_MEAN3", OBJPROP_STYLE, STYLE_SOLID);
     }
   else
      ObjectDelete(0, "XAU_MEAN3");
  }

void DetachTrendOsc()
  {
   int wins = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int w = wins - 1; w >= 1; w--)
     {
      int n = ChartIndicatorsTotal(0, w);
      for(int i = n - 1; i >= 0; i--)
        {
         string name = ChartIndicatorName(0, w, i);
         if(StringFind(name, "MACD") >= 0 || StringFind(name, "ADX") >= 0 ||
            StringFind(name, "RSI") >= 0 || StringFind(name, "Stochastic") >= 0)
            ChartIndicatorDelete(0, w, name);
        }
     }
   ReleaseHandle(g_chart_macd);
   ReleaseHandle(g_chart_adx);
   ReleaseHandle(g_chart_rsi);
   ReleaseHandle(g_chart_stoch);
   g_trend_osc_on = false;
  }

void OnTimer()
  {
#ifdef EA_BUILD_WITH_AI
   EnsureOscHandles();
   // 休市没有跳动时 OnTick 不来，快照仍要写，否则桥一直「等待 EA 快照」
   AiRefreshAssist();
   if(TimeCurrent() - g_last_ui_refresh >= 2)
     {
      UpdateDashboard();
      g_last_ui_refresh = TimeCurrent();
     }
#endif
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   DetachTrendOsc();
   DetachShortMAs();
   ClearBgImage();
   AiClearLevelObjectsSafe();
   AiReleaseIndicators();
   ObjectDelete(0, "XAU_LIQ_HI");
   ObjectDelete(0, "XAU_LIQ_LO");
   ObjectDelete(0, "XAU_AVG_BUY");
   ObjectDelete(0, "XAU_AVG_SELL");
   ObjectDelete(0, "XAU_MEAN3");
   g_ui_controls_ready = false;
   DeletePanelButtons();
   DeleteDashboard();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
      return;
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == EDIT_TP)
        {
         g_tp_edit_focus = true;
         g_sl_edit_focus = false;
         g_lot_edit_focus = false;
         g_side_edit_focus = false;
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         return;
        }
      if(sparam == EDIT_SL)
        {
         g_sl_edit_focus = true;
         g_tp_edit_focus = false;
         g_lot_edit_focus = false;
         g_side_edit_focus = false;
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         return;
        }
      if(sparam == EDIT_LOT)
        {
         g_lot_edit_focus = true;
         g_tp_edit_focus = false;
         g_sl_edit_focus = false;
         g_side_edit_focus = false;
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         return;
        }
      if(sparam == EDIT_TP_BUY || sparam == EDIT_TP_SELL)
        {
         g_side_edit_focus = true;
         g_tp_edit_focus = false;
         g_sl_edit_focus = false;
         g_lot_edit_focus = false;
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         return;
        }
      if(StringFind(sparam, "XAU_BTN_") == 0)
        {
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         HandlePanelClick(sparam);
        }
      return;
     }
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
     {
      if(sparam == EDIT_TP)
        {
         g_tp_edit_focus = false;
         string t = ObjectGetString(0, EDIT_TP, OBJPROP_TEXT);
         ApplyTpFromPanel(StringToDouble(t));
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         UpdateDashboard();
        }
      else if(sparam == EDIT_SL)
        {
         g_sl_edit_focus = false;
         string t = ObjectGetString(0, EDIT_SL, OBJPROP_TEXT);
         ApplySlFromPanel(StringToDouble(t));
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         UpdateDashboard();
        }
      else if(sparam == EDIT_LOT)
        {
         g_lot_edit_focus = false;
         string t = ObjectGetString(0, EDIT_LOT, OBJPROP_TEXT);
         ApplyLotFromPanel(StringToDouble(t));
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         UpdateDashboard();
        }
      else if(sparam == EDIT_TP_BUY || sparam == EDIT_TP_SELL)
        {
         g_side_edit_focus = false;
         ApplySideTpFromPanel();
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, false);
         CheckProfitExits();
         UpdateDashboard();
        }
     }
  }

void OnTick()
  {
   DrawAvgPriceLines();
   // 从号：先同步暂停位，再跟指令（主号点恢复后从号不能还停着）
   CfgPullPausedOnly();
   CfgSyncRuntime();
   TrackSpread2H();
   AiRefreshAssist(); // 写快照、读方向。开仓在 RunGridMode，且只用用户止盈止损和开仓时段
   UpdateDayClock();
   NewsCalendar_Refresh(g_UseNewsFilter, g_NewsBeforeMin, g_NewsAfterMin, NewsRefreshSec);
   ManageNewsFlatten(); // 新闻窗口刚开始 → 清仓

   const bool editing = (g_tp_edit_focus || g_sl_edit_focus || g_lot_edit_focus || g_side_edit_focus);

   if(g_sl_pause_until > 0 && TimeCurrent() >= g_sl_pause_until)
     {
      Print("止损冷却结束，可重新开仓");
      g_sl_pause_until = 0;
     }

   // 从号始终跟随主号指令（含平仓/暂停），即使本机已暂停也能收到恢复/平仓
   ProcessCmdSignalFollow();

   // 冷却期仍允许止盈/止损检查（防平仓失败残留）
   if(CheckProfitExits())
     {
      if(!editing)
         UpdateDashboard();
      return;
     }

   // 新闻窗口 / 止损冷却：只禁开仓，可刷新面板
   if(BotFullyPaused() || (g_sl_pause_until > 0 && TimeCurrent() < g_sl_pause_until) ||
      NewsCalendar_IsFrozen())
     {
      if(!editing)
         UpdateDashboard();
      return;
     }

   ManageHedgeLogic();
   RunGridMode();
   if(editing)
     {
      if(TimeCurrent() - g_last_ui_refresh >= 2)
        {
         UpdateDashboard();
         g_last_ui_refresh = TimeCurrent();
        }
     }
   else
      UpdateDashboard();
  }
//+------------------------------------------------------------------+

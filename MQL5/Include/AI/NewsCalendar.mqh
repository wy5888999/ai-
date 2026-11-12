//+------------------------------------------------------------------+
//| NewsCalendar.mqh                                                 |
//| MT5 经济日历：仅美国(US) + 仅高影响 → 新闻窗口内冻结新开仓       |
//+------------------------------------------------------------------+
#ifndef NEWS_CALENDAR_MQH
#define NEWS_CALENDAR_MQH

struct NewsFreezeInfo
  {
   bool     enabled_ok;     // 日历是否读到过数据
   bool     frozen;         // 当前是否在冻结窗口
   datetime event_time;     // 相关事件时间(服务器时区)
   string   event_name;     // 事件名
   string   status;         // 面板短状态
  };

NewsFreezeInfo g_news;
datetime       g_news_last_refresh = 0;

string NewsCalendar_ShortName(const string name, const int maxLen = 22)
  {
   if(StringLen(name) <= maxLen)
      return name;
   return StringSubstr(name, 0, maxLen) + "...";
  }

// 刷新美国高影响事件；before/after 为分钟
void NewsCalendar_Refresh(const bool use_news,
                          const int before_min,
                          const int after_min,
                          const int refresh_sec = 30)
  {
   if(!use_news)
     {
      g_news.enabled_ok = true;
      g_news.frozen = false;
      g_news.event_time = 0;
      g_news.event_name = "";
      g_news.status = "新闻过滤关";
      return;
     }

   // 冻结状态每个 tick 都可按缓存事件重算；完整拉日历限频
   datetime now = TimeTradeServer();
   bool need_fetch = (g_news_last_refresh == 0 ||
                      now - g_news_last_refresh >= MathMax(10, refresh_sec));

   static datetime s_events[];
   static string   s_names[];
   static int      s_count = 0;
   static bool     s_fetch_ok = false;

   if(!need_fetch && !s_fetch_ok && s_count == 0)
     {
      g_news.enabled_ok = false;
      g_news.frozen = false;
      g_news.status = "日历无数据";
      g_news.event_name = "";
      g_news.event_time = 0;
      return;
     }

   if(need_fetch)
     {
      g_news_last_refresh = now;
      datetime from = now - (datetime)(MathMax(after_min, 1) * 60) - 3600;
      datetime to   = now + 7 * 24 * 3600; // 未来一周，用于面板「下一场」

      MqlCalendarValue values[];
      ResetLastError();
      // 优先按国家 US；失败再试货币 USD
      bool ok = CalendarValueHistory(values, from, to, "US", NULL);
      if(!ok)
         ok = CalendarValueHistory(values, from, to, NULL, "USD");

      ArrayResize(s_events, 0);
      ArrayResize(s_names, 0);
      s_count = 0;
      s_fetch_ok = ok;

      if(!ok)
        {
         g_news.enabled_ok = false;
         g_news.frozen = false;
         g_news.status = "日历无数据";
         g_news.event_name = "";
         g_news.event_time = 0;
         // 读不到日历时不冻仓，避免误杀全部交易
         return;
        }

      g_news.enabled_ok = true;
      int n = ArraySize(values);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;

         int k = s_count;
         ArrayResize(s_events, k + 1);
         ArrayResize(s_names, k + 1);
         s_events[k] = values[i].time;
         s_names[k]  = ev.name;
         s_count++;
        }
     }

   int before_sec = MathMax(0, before_min) * 60;
   int after_sec  = MathMax(0, after_min) * 60;

   bool frozen = false;
   datetime freeze_t = 0;
   string   freeze_n = "";
   datetime next_t = 0;
   string   next_n = "";

   for(int i = 0; i < s_count; i++)
     {
      datetime t = s_events[i];
      datetime ws = t - before_sec;
      datetime we = t + after_sec;

      if(now >= ws && now <= we)
        {
         // 取时间上最近的一场作为显示
         if(!frozen || MathAbs((long)(t - now)) < MathAbs((long)(freeze_t - now)))
           {
            frozen = true;
            freeze_t = t;
            freeze_n = s_names[i];
           }
        }

      if(t >= now && (next_t == 0 || t < next_t))
        {
         next_t = t;
         next_n = s_names[i];
        }
     }

   g_news.frozen = frozen;
   if(frozen)
     {
      g_news.event_time = freeze_t;
      g_news.event_name = freeze_n;
      int left = (int)(freeze_t + after_sec - now);
      if(left < 0) left = 0;
      g_news.status = StringFormat("新闻冻结 %ds", left);
     }
   else if(next_t > 0)
     {
      g_news.event_time = next_t;
      g_news.event_name = next_n;
      int eta = (int)(next_t - now);
      g_news.status = StringFormat("下高影响 %dm", eta / 60);
     }
   else
     {
      g_news.event_time = 0;
      g_news.event_name = "";
      g_news.status = "无高影响";
     }
  }

bool NewsCalendar_IsFrozen()
  {
   return g_news.frozen;
  }

string NewsCalendar_PanelLine()
  {
   if(g_news.status == "新闻过滤关")
      return "新闻  过滤关闭";
   if(g_news.status == "日历无数据")
      return "新闻  日历无数据(不冻结)";
   if(g_news.frozen)
      return StringFormat("新闻  冻结 | %s | %s",
                          TimeToString(g_news.event_time, TIME_MINUTES),
                          NewsCalendar_ShortName(g_news.event_name));
   if(g_news.event_time > 0)
      return StringFormat("新闻  %s | %s | %s",
                          g_news.status,
                          TimeToString(g_news.event_time, TIME_DATE|TIME_MINUTES),
                          NewsCalendar_ShortName(g_news.event_name));
   return "新闻  " + g_news.status;
  }

#endif
//+------------------------------------------------------------------+

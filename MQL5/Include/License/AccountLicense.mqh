//+------------------------------------------------------------------+
//| AccountLicense.mqh                                               |
//| 独立账号授权 + 窗口数限制（绑几个 MT5 就能开几个终端窗口）         |
//+------------------------------------------------------------------+
#ifndef ACCOUNT_LICENSE_MQH
#define ACCOUNT_LICENSE_MQH

// 须与 tools/data/config.json 的 license_secret 完全一致
#define LICENSE_SECRET "CHANGE_THIS_SECRET_Aa112233@_2026"
#define LICENSE_WINDOW_STALE_SEC 120

string g_license_window_file = "";

ulong License_Hash(const string text)
  {
   ulong hash = 2166136261;
   int n = StringLen(text);
   for(int i = 0; i < n; i++)
     {
      hash ^= (uchar)StringGetCharacter(text, i);
      hash = (hash * 16777619) & 0xFFFFFFFF;
     }
   return hash;
  }

bool License_Parse(const string key, long &account, string &expiryYmd, ulong &checksum)
  {
   string parts[];
   if(StringSplit(key, '-', parts) != 3)
      return false;
   account = StringToInteger(parts[0]);
   expiryYmd = parts[1];
   if(StringLen(expiryYmd) != 8)
      return false;
   checksum = (ulong)StringToInteger(parts[2]);
   return (account > 0);
  }

string License_ReadFile(const string filename)
  {
   int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle == INVALID_HANDLE)
         return "";
     }
   string line = "";
   if(!FileIsEnding(handle))
      line = FileReadString(handle);
   FileClose(handle);
   StringTrimLeft(line);
   StringTrimRight(line);
   return line;
  }

bool License_RequireHeartbeat()
  {
   string hb = "licenses\\service.heartbeat";
   if(!FileIsExist(hb, FILE_COMMON) && !FileIsExist(hb))
     {
      Print("授权模块：未检测到授权工具心跳，请先打开并登录「授权工具」");
      return false;
     }
   return true;
  }

int License_ReadMaxWindows()
  {
   // 优先读 service.meta：{"max_windows":N,...}
   string raw = License_ReadFile("licenses\\service.meta");
   if(raw == "")
      raw = License_ReadFile("licenses\\service.heartbeat");
   if(raw == "")
      return 1;
   int pos = StringFind(raw, "\"max_windows\"");
   if(pos < 0)
      return 1;
   pos = StringFind(raw, ":", pos);
   if(pos < 0)
      return 1;
   string num = "";
   for(int i = pos + 1; i < StringLen(raw); i++)
     {
      ushort ch = StringGetCharacter(raw, i);
      if(ch >= '0' && ch <= '9')
         num += ShortToString(ch);
      else if(StringLen(num) > 0)
         break;
     }
   int n = (int)StringToInteger(num);
   return (n > 0 ? n : 1);
  }

string License_MakeWindowId()
  {
   // 同一终端数据目录 = 同一个窗口槽位
   string path = TerminalInfoString(TERMINAL_DATA_PATH);
   ulong h = License_Hash(path);
   long acc = AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("%I64d_%I64u", acc, h);
  }

int License_CountActiveWindows(const string selfFile)
  {
   string filter = "licenses\\windows\\*.win";
   string fname;
   long search = FileFindFirst(filter, fname, FILE_COMMON);
   if(search == INVALID_HANDLE)
      return 0;

   datetime now = TimeCurrent();
   int active = 0;
   do
     {
      string full = "licenses\\windows\\" + fname;
      // 自己的槽位始终算占用
      if(full == selfFile)
        {
         active++;
         continue;
        }
      int h = FileOpen(full, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h == INVALID_HANDLE)
         continue;
      string line1 = "";
      string line2 = "";
      if(!FileIsEnding(h)) line1 = FileReadString(h);
      if(!FileIsEnding(h)) line2 = FileReadString(h);
      FileClose(h);
      // 以文件本地修改时间为准（EA 每约20秒 Touch）；勿用服务器时间与文件时间混比
      datetime fileMod = (datetime)FileGetInteger(full, FILE_MODIFY_DATE, FILE_COMMON);
      datetime localNow = TimeLocal();
      if(fileMod <= 0 || (localNow - fileMod) > LICENSE_WINDOW_STALE_SEC)
        {
         FileDelete(full, FILE_COMMON);
         continue;
        }
      active++;
     }
   while(FileFindNext(search, fname));
   FileFindClose(search);
   return active;
  }

bool License_WriteWindowSlot(const string file)
  {
   FolderCreate("licenses\\windows", FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      Print("授权模块：无法写入窗口槽位文件");
      return false;
     }
   FileWriteString(h, IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\n");
   FileWriteString(h, IntegerToString((long)TimeCurrent()) + "\n");
   FileClose(h);
   return true;
  }

bool License_ClaimWindow()
  {
   int maxWin = License_ReadMaxWindows();
   string id = License_MakeWindowId();
   string file = "licenses\\windows\\" + id + ".win";
   g_license_window_file = file;

   // 已有本窗口槽位：续约
   if(FileIsExist(file, FILE_COMMON))
     {
      if(!License_WriteWindowSlot(file))
         return false;
      PrintFormat("授权模块：窗口槽位续约成功（上限 %d）", maxWin);
      return true;
     }

   int active = License_CountActiveWindows(file);
   if(active >= maxWin)
     {
      PrintFormat(
         "授权模块：窗口已满（当前活跃 %d / 上限 %d）。请管理员再绑定 MT5 账号后，客户重新登录授权工具。",
         active, maxWin);
      g_license_window_file = "";
      return false;
     }

   if(!License_WriteWindowSlot(file))
     {
      g_license_window_file = "";
      return false;
     }
   PrintFormat("授权模块：占用窗口槽位 %d/%d", active + 1, maxWin);
   return true;
  }

void License_TouchWindow()
  {
   if(g_license_window_file == "")
      return;
   License_WriteWindowSlot(g_license_window_file);
  }

void License_ReleaseWindow()
  {
   if(g_license_window_file == "")
      return;
   FileDelete(g_license_window_file, FILE_COMMON);
   g_license_window_file = "";
  }

bool License_CheckAccount()
  {
   if(LICENSE_SECRET == "" || LICENSE_SECRET == "CHANGE_THIS_SECRET_KEY_2026")
     {
      Print("授权模块：请先在 AccountLicense.mqh 中修改 LICENSE_SECRET 后重新编译。");
      return false;
     }

   if(!License_RequireHeartbeat())
      return false;

   long curAccount = AccountInfoInteger(ACCOUNT_LOGIN);
   string filename = "licenses\\" + IntegerToString(curAccount) + ".lic";
   string key = License_ReadFile(filename);
   if(key == "")
     {
      PrintFormat("授权模块：未找到公共授权文件 licenses\\%I64d.lic（请登录授权工具；该MT5须已绑定）", curAccount);
      return false;
     }

   long licAccount = 0;
   string expiry = "";
   ulong licChecksum = 0;
   if(!License_Parse(key, licAccount, expiry, licChecksum))
     {
      Print("授权模块：授权文件格式错误");
      return false;
     }

   if(licAccount != curAccount)
     {
      PrintFormat("授权模块：文件账号 %I64d 与当前账号 %I64d 不符", licAccount, curAccount);
      return false;
     }

   MqlDateTime nowDt;
   TimeToStruct(TimeCurrent(), nowDt);
   string today = StringFormat("%04d%02d%02d", nowDt.year, nowDt.mon, nowDt.day);
   if(StringCompare(today, expiry) > 0)
     {
      PrintFormat("授权模块：授权已于 %s 过期", expiry);
      return false;
     }

   string payload = IntegerToString(licAccount) + "|" + expiry + "|" + LICENSE_SECRET;
   ulong expect = License_Hash(payload) % 100000000;
   if(expect != licChecksum)
     {
      Print("授权模块：校验失败（密钥不一致或授权文件被篡改）");
      return false;
     }

   if(!License_ClaimWindow())
      return false;

   PrintFormat("授权模块：通过（账号 %I64d，有效期至 %s，可开窗口 %d）",
               licAccount, expiry, License_ReadMaxWindows());
   return true;
  }

#endif
//+------------------------------------------------------------------+

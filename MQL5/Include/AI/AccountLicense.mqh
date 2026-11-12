//+------------------------------------------------------------------+
//| AccountLicense.mqh                                               |
//| 独立账号授权：从 MT5「公共文件夹」读 .lic，支持一授权多终端        |
//+------------------------------------------------------------------+
#ifndef ACCOUNT_LICENSE_MQH
#define ACCOUNT_LICENSE_MQH

// 须与 tools/data/config.json 的 license_secret 完全一致
#define LICENSE_SECRET "CHANGE_THIS_SECRET_Aa112233@_2026"

ulong License_Hash(const string text)
  {
   ulong hash = 2166136261UL;
   int n = StringLen(text);
   for(int i = 0; i < n; i++)
     {
      hash ^= (uchar)StringGetCharacter(text, i);
      hash = (hash * 16777619UL) & 0xFFFFFFFFUL;
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
   // FILE_COMMON：所有 MT5 终端共用 Common\Files
   int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      // 兼容旧路径：本终端 Files\
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
   ulong expect = License_Hash(payload) % 100000000UL;
   if(expect != licChecksum)
     {
      Print("授权模块：校验失败（密钥不一致或授权文件被篡改）");
      return false;
     }

   PrintFormat("授权模块：通过（账号 %I64d，有效期至 %s）", licAccount, expiry);
   return true;
  }

#endif

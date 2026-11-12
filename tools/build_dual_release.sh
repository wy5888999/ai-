#!/bin/zsh
# 两套面板，都带 AI（只教学，不自动开仓）：
#   mac  = 大面板 → 本机每个 MT5 + 桌面 mac马丁
#   win  = 矮面板 → 桌面 win马丁
set -euo pipefail
export LC_ALL=C

BOTTLE="MetaTrader 5"
CXBIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
MT5="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE/drive_c/Program Files/MetaTrader 5"
SRC_ROOT="/Applications/EA/MQL5"
MQ5="$SRC_ROOT/Experts/XAUUSD_Grid_EA.mq5"
OUT="/Applications/EA/build"
mkdir -p "$OUT"

set_ai() {
  python3 - <<PY
from pathlib import Path
p = Path("$MQ5")
lines = p.read_text(encoding="utf-8").splitlines(True)
out=[]; done=False
for line in lines:
    if (not done) and ("#define EA_BUILD_WITH_AI" in line):
        out.append("#define EA_BUILD_WITH_AI\n" if int("$1")==1 else "//#define EA_BUILD_WITH_AI\n")
        done=True
    else:
        out.append(line)
assert done
p.write_text("".join(out), encoding="utf-8")
print("AI_BUILD=$1")
PY
}

set_panel() {
  python3 - <<PY
from pathlib import Path
p = Path("$MQ5")
lines = p.read_text(encoding="utf-8").splitlines(True)
out=[]; done=False
for line in lines:
    if (not done) and ("#define EA_PANEL_WIN" in line):
        out.append("#define EA_PANEL_WIN\\n" if int("$1")==1 else "//#define EA_PANEL_WIN\\n")
        done=True
    else:
        out.append(line)
assert done, "missing EA_PANEL_WIN"
p.write_text("".join(out), encoding="utf-8")
print("PANEL_WIN=$1")
PY
}

compile_tag() {
  local panel=$1 tag=$2
  set_ai 1
  set_panel "$panel"
  mkdir -p "$MT5/MQL5/Experts" "$MT5/MQL5/Include/AI"
  cp -f "$MQ5" "$MT5/MQL5/Experts/"
  cp -f "$SRC_ROOT/Include/AI/"*.mqh "$MT5/MQL5/Include/AI/"
  pkill -f 'MetaEditor64.exe' 2>/dev/null || true
  sleep 1
  ( cd "$MT5" && "$CXBIN/wine" --bottle "$BOTTLE" MetaEditor64.exe "/compile:MQL5\\Experts\\XAUUSD_Grid_EA.mq5" /log ) || true
  sleep 2
  local log="$MT5/MQL5/Experts/XAUUSD_Grid_EA.log"
  local text; text=$(iconv -f UTF-16LE -t UTF-8 "$log" 2>/dev/null || cat "$log")
  echo "$text" | grep "Result:" | tail -1
  echo "$text" | grep -q "Result: 0 errors" || { echo FAIL_$tag; echo "$text" | grep error | head -20; exit 1; }
  cp -f "$MT5/MQL5/Experts/XAUUSD_Grid_EA.ex5" "$OUT/XAUUSD_Grid_EA.${tag}.ex5"
}

compile_indicator() {
  mkdir -p "$MT5/MQL5/Indicators"
  cp -f "$SRC_ROOT/Indicators/XAU_ShortMA.mq5" "$MT5/MQL5/Indicators/"
  pkill -f 'MetaEditor64.exe' 2>/dev/null || true
  sleep 1
  ( cd "$MT5" && "$CXBIN/wine" --bottle "$BOTTLE" MetaEditor64.exe "/compile:MQL5\\Indicators\\XAU_ShortMA.mq5" /log ) || true
  sleep 2
  local log="$MT5/MQL5/Indicators/XAU_ShortMA.log"
  local text; text=$(iconv -f UTF-16LE -t UTF-8 "$log" 2>/dev/null || cat "$log")
  echo "$text" | grep "Result:" | tail -1
  echo "$text" | grep -q "Result: 0 errors" || { echo FAIL_shortma; echo "$text" | grep error | head -20; exit 1; }
  cp -f "$MT5/MQL5/Indicators/XAU_ShortMA.ex5" "$OUT/XAU_ShortMA.ex5"
}

compile_indicator
compile_tag 0 mac
compile_tag 1 win
set_panel 0
set_ai 1

MACEX="$OUT/XAUUSD_Grid_EA.mac.ex5"
WINEX="$OUT/XAUUSD_Grid_EA.win.ex5"
cp -f "$MACEX" "$SRC_ROOT/Experts/XAUUSD_Grid_EA.ex5"

CX="$HOME/Library/Application Support/CrossOver/Bottles"
NATIVE="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5"
while IFS= read -r dir; do
  [ -d "$dir" ] || continue
  cp -f "$MACEX" "$dir/XAUUSD_Grid_EA.ex5"
done < <(
  for b in "$CX"/MT5_* "$CX/MetaTrader 5"; do
    [ -d "$b" ] || continue
    echo "$b/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    find "$b/drive_c/users" -type d -path '*/MetaQuotes/Terminal/*/MQL5/Experts' 2>/dev/null
  done
  echo "$NATIVE/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
  find "$NATIVE" -type d -path '*/MQL5/Experts' 2>/dev/null
)

cp -f "$MACEX" "$HOME/Desktop/mac马丁/XAUUSD_Grid_EA.ex5"
cp -f "$WINEX" "$HOME/Desktop/win马丁/XAUUSD_Grid_EA.ex5"
cp -f "$OUT/XAU_ShortMA.ex5" "$HOME/Desktop/mac马丁/XAU_ShortMA.ex5"
cp -f "$OUT/XAU_ShortMA.ex5" "$HOME/Desktop/win马丁/XAU_ShortMA.ex5"

while IFS= read -r experts; do
  [ -d "$experts" ] || continue
  ind="${experts%/Experts}/Indicators"
  mkdir -p "$ind"
  cp -f "$OUT/XAU_ShortMA.ex5" "$ind/XAU_ShortMA.ex5"
done < <(
  for b in "$CX"/MT5_* "$CX/MetaTrader 5"; do
    [ -d "$b" ] || continue
    echo "$b/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    find "$b/drive_c/users" -type d -path '*/MetaQuotes/Terminal/*/MQL5/Experts' 2>/dev/null
  done
  echo "$NATIVE/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
  find "$NATIVE" -type d -path '*/MQL5/Experts' 2>/dev/null
)

# 分享包带上桥（不含真实 api_key）
for pack in "$HOME/Desktop/mac马丁" "$HOME/Desktop/win马丁"; do
  mkdir -p "$pack/AI/data"
  cp -f "/Applications/EA/tools/ai_signal_bridge.py" "$pack/AI/ai_signal_bridge.py"
  cp -f "/Applications/EA/tools/data/deepseek_config.example.json" "$pack/AI/data/deepseek_config.example.json"
  rm -f "$pack/AI/data/deepseek_config.json"
done
cp -f "/Applications/EA/tools/打开AI.bat" "$HOME/Desktop/win马丁/打开AI.bat"

python3 - <<'PY'
from pathlib import Path
mac = Path.home() / "Desktop/mac马丁/使用说明.txt"
win = Path.home() / "Desktop/win马丁/使用说明.txt"
mac_txt = """Mac 马丁 EA（仅 Mac）
====================
本包只给 Mac 用（CrossOver / Mac 版 MT5）。
Windows 请用另一包：桌面「win马丁」。
本包已带 AI 辅助（只教学、画支撑压力，不会因为 AI 开仓）。
面板是 Mac 大面板（字大、分行，和 Mac 上看到的一样）。不要把这份 ex5 拷到 Windows。

一、安装
  双击：一键安装.command
  或终端：
    cd ~/Desktop/mac马丁
    chmod +x 一键安装.sh && ./一键安装.sh

  会做两件事：导入 EA + 串联各 MT5 的 Common（主从跟单必需）

二、挂图
  卸掉旧 EA，再把 XAUUSD_Grid_EA 拖到黄金图。
  主号：SharedConfigMaster = true（整机只能 1 个）
  从号：SharedConfigMaster = false
  UseSharedConfig = true
  UseExternalAI = true（默认开；不想看 AI 就关掉）
  每个交易账号只登录一个 MT5，不要双开同一账号。
  面板已缩小，按钮在面板最下方：入场多/空、平多#1/平空#1、平多、平空、暂停、全平。

三、更新
  换新的 XAUUSD_Grid_EA.ex5 后，再跑一次「一键安装」，图表上卸掉重挂。

四、AI（自己的 DeepSeek 密钥，不要用别人的）
  1. 复制 AI/data/deepseek_config.example.json
     为 AI/data/deepseek_config.json
  2. 把 api_key 改成你自己的密钥
  3. 终端：
       cd ~/Desktop/mac马丁/AI
       python3 -m pip install certifi
       python3 ai_signal_bridge.py
  4. 保持这个窗口开着。EA 把行情写到 Common/Files/ai，桥把教学写回去。
  5. 面板只留两行说明。没有密钥或没开桥时，面板会写「等桥写出 teach」。
"""
win_txt = """Windows 马丁 EA（仅 Windows）
============================
本包只给 Windows 用。
Mac 请用另一包：桌面「mac马丁」。
本包已带 AI 辅助（只教学、画支撑压力，不会因为 AI 开仓）。
面板是 Windows 矮面板，按钮留在屏幕里面。不要用 Mac 那份 ex5。

一、安装
  1. 关掉 MT5
  2. 打开 MT5 → 文件 → 打开数据文件夹
  3. 进入 MQL5\\Experts\\
  4. 把本目录里的 XAUUSD_Grid_EA.ex5 拷进去（覆盖旧文件）
     把 XAU_ShortMA.ex5 拷到同一数据文件夹的 MQL5\\Indicators\\
  5. 打开 MT5，导航器里右键专家顾问 → 刷新
  6. 把 XAUUSD_Grid_EA 拖到黄金图
  7. 图表上卸掉旧的再拖一次，按钮才会按新面板位置显示

  多开多个 MT5 时：每个终端的数据文件夹都要拷一份，或拷完后在各终端刷新。

二、主从跟单（同一台 Windows 电脑）
  同一 Windows 用户下，各 MT5 已共用 Common\\Files，一般不用额外串联。
  主号：SharedConfigMaster = true（整机只能 1 个）
  从号：SharedConfigMaster = false
  UseSharedConfig = true
  UseExternalAI = true（默认开；不想看 AI 就关掉）
  每个交易账号只登录一个 MT5，不要双开同一账号。

三、面板
  面板改窄、改矮，按钮贴在面板底部，小屏幕也能看到：
  入场多 / 入场空
  平多#1 / 平空#1
  平多 / 平空 / 暂停 / 全平
  若仍被行情图挡住：把下方「交易/工具箱」那一条拉矮一点。

四、打开 AI（双击即可，密钥用自己的）
  先装 Python 3：https://www.python.org/downloads/
  安装时勾选 Add python.exe to PATH。

  双击本文件夹里的「打开AI.bat」。
  第一次会打开记事本，把 api_key 换成自己的 DeepSeek 密钥，保存。
  窗口要一直开着。关掉就没有新的教学。

  路径（把「用户名」换成这台电脑的登录名）：
  1) EA 文件
     本包里的 XAUUSD_Grid_EA.ex5
     拷到：MT5 → 文件 → 打开数据文件夹 → MQL5\\Experts\\
     实际位置类似：
     C:\\Users\\用户名\\AppData\\Roaming\\MetaQuotes\\Terminal\\一串字母\\MQL5\\Experts\\
     那串字母不要猜，用菜单打开。

  2) 密钥（不要发给别人，每人自己填）
     本包\\AI\\data\\deepseek_config.json

  3) 桥和 EA 交换文件的公共目录（所有 MT5 共用，不用每个号拷）
     C:\\Users\\用户名\\AppData\\Roaming\\MetaQuotes\\Terminal\\Common\\Files\\ai\\
     在 MT5 里看：文件 → 打开公共数据文件夹，再进 ai
     EA 写 snapshot.txt，桥写 teach.txt、signal.txt

  EA 输入 UseExternalAI = true。
  没有密钥或没开桥时，面板显示「等桥写出 teach」，手动开仓不受影响。

五、注意
  本 ex5 为 X64 Regular（兼容多数电脑）。
  不要用 AVX2 专用编译版发给客户。
  更新时覆盖 Experts 里的 ex5 后，图表上卸掉 EA 再挂一次。
"""
mac.write_text(mac_txt, encoding="utf-8")
win.write_text(win_txt, encoding="utf-8")
print("docs updated")
PY

cd "$HOME/Desktop"
rm -f mac马丁.zip win马丁.zip
ditto -c -k --sequesterRsrc --keepParent mac马丁 mac马丁.zip
ditto -c -k --sequesterRsrc --keepParent win马丁 win马丁.zip
echo "mac: $(shasum -a 256 "$MACEX")"
echo "win: $(shasum -a 256 "$WINEX")"

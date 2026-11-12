#!/bin/zsh
#======================================================================
# mac_link_mt5_common.sh
# 把本机所有 CrossOver MT5 瓶 + Mac 原生 MT5 的 Common/Files
# 软链到同一个中枢目录，让 EA 主号/从号能共用指令文件。
#
# 用法：
#   chmod +x mac_link_mt5_common.sh
#   ./mac_link_mt5_common.sh
#
# 建议先关掉所有 MT5，再运行。
# 可选环境变量：MT5_SHARED_HUB=/自定义/路径/Files
#======================================================================

set -euo pipefail

HUB="${MT5_SHARED_HUB:-$HOME/MT5_Shared_Common/Files}"
CX_ROOT="$HOME/Library/Application Support/CrossOver/Bottles"
MAC_NATIVE_COMMON="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common"

echo "========================================"
echo " MT5 Common/Files 串联工具 (Mac)"
echo "========================================"
echo "中枢目录: $HUB"
echo

mkdir -p "$HUB"

link_one() {
  local target="$1"
  local label="$2"
  local parent
  parent="$(dirname "$target")"
  mkdir -p "$parent"

  if [ -L "$target" ]; then
    local cur
    cur="$(readlink "$target" || true)"
    if [ "$cur" = "$HUB" ]; then
      echo "  [已是] $label"
      return 0
    fi
    echo "  [替换旧链] $label  (原→ $cur)"
    rm "$target"
  elif [ -d "$target" ]; then
    if [ "$(ls -A "$target" 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
      local bak="${target}.bak.$(date +%Y%m%d%H%M%S)"
      echo "  [备份非空] $label → $bak"
      mv "$target" "$bak"
      cp -n "$bak"/* "$HUB"/ 2>/dev/null || true
    else
      rmdir "$target"
    fi
  elif [ -e "$target" ]; then
    echo "  [跳过] $label  不是目录: $target" >&2
    return 1
  fi

  ln -s "$HUB" "$target"
  echo "  [已链] $label"
}

bottle_looks_mt5() {
  local name="$1"
  local bottle="$2"
  [[ "$name" == *[Mm][Tt]5* || "$name" == *[Mm]eta[Tt]rader* ]] && return 0
  [ -d "$bottle/drive_c/users/crossover/AppData/Roaming/MetaQuotes/Terminal" ] && return 0
  [ -d "$bottle/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal" ] && return 0
  return 1
}

echo "1) CrossOver 容器"
if [ -d "$CX_ROOT" ]; then
  local_count=0
  for bottle in "$CX_ROOT"/*(/N); do
    [ -d "$bottle" ] || continue
    name="${bottle:t}"
    if ! bottle_looks_mt5 "$name" "$bottle"; then
      continue
    fi
    # 优先 crossover 用户目录（CrossOver 默认），否则 user
    if [ -d "$bottle/drive_c/users/crossover" ] || [[ "$name" == *[Mm][Tt]5* || "$name" == *[Mm]eta[Tt]rader* ]]; then
      common="$bottle/drive_c/users/crossover/AppData/Roaming/MetaQuotes/Terminal/Common"
    else
      common="$bottle/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common"
    fi
    # 若 crossover 下没有、user 下有，改用 user
    if [ ! -d "$common" ] && [ -d "$bottle/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common" ]; then
      common="$bottle/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common"
    fi
    mkdir -p "$common"
    link_one "$common/Files" "CX:$name"
    local_count=$((local_count + 1))
  done
  if [ "$local_count" -eq 0 ]; then
    echo "  未找到名称含 MT5/MetaTrader 或已有 MetaQuotes 的瓶"
  fi
else
  echo "  未找到: $CX_ROOT"
fi

echo
echo "2) Mac 原生 MT5"
if [ -d "$(dirname "$MAC_NATIVE_COMMON")" ] || [ -d "$HOME/Library/Application Support/net.metaquotes.wine.metatrader5" ]; then
  mkdir -p "$MAC_NATIVE_COMMON"
  link_one "$MAC_NATIVE_COMMON/Files" "Mac原生MT5"
else
  echo "  未安装 Mac 原生 MT5，跳过"
fi

echo
echo "3) 探测写入"
stamp="hub-ok $(date '+%Y-%m-%d %H:%M:%S')"
echo "$stamp" > "$HUB/_shared_hub_ok.txt"
echo "  $HUB/_shared_hub_ok.txt"
echo "  $stamp"

echo
echo "4) 链接一览"
if [ -d "$CX_ROOT" ]; then
  for bottle in "$CX_ROOT"/*(/N); do
    [ -d "$bottle" ] || continue
    name="${bottle:t}"
    for user in crossover user; do
      p="$bottle/drive_c/users/$user/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
      if [ -L "$p" ]; then
        echo "  $name ($user) → $(readlink "$p")"
      elif [ -d "$p" ]; then
        echo "  $name ($user) = 真实目录(未链)"
      fi
    done
  done
fi
if [ -L "$MAC_NATIVE_COMMON/Files" ]; then
  echo "  Mac原生 → $(readlink "$MAC_NATIVE_COMMON/Files")"
elif [ -d "$MAC_NATIVE_COMMON/Files" ]; then
  echo "  Mac原生 = 真实目录(未链)"
fi

echo
echo "========================================"
echo " 完成。请对方按下面挂 EA："
echo "  · 全机只 1 个主号 SharedConfigMaster=true"
echo "  · 其余从号 SharedConfigMaster=false"
echo "  · 全部 UseSharedConfig=true"
echo "  · 只在主号点面板"
echo " 新建瓶子后重新运行本脚本一次即可。"
echo "========================================"

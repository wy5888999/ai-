#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DeepSeek → MT5 方向桥

读取 EA 写入的 Common/Files/ai/snapshot.txt，
调用 deepseek-v4-pro，写出：
  ai/signal.txt  — DIR,CONF,FREEZE,短因（兼容旧格式）
  ai/teach.txt   — 键值：方向、支撑压力（仅说明）

EA 只采用 DIR。止盈、止损、开仓时段用 EA 输入，不采用模型给出的价位当止盈止损。

DIR: UP / DOWN / LEAN_UP / LEAN_DOWN / FLAT
CONF: 0-100
FREEZE: 0=可顺着方向开/加  1=先别开也别加

用法：
  1. 复制 data/deepseek_config.example.json → deepseek_config.json，填入 api_key
  2. EA 输入：UseExternalAI=true
  3. python ai_signal_bridge.py
"""

from __future__ import annotations

import atexit
import argparse
import json
import os
import re
import signal
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_CFG = ROOT / "data" / "deepseek_config.json"
EXAMPLE_CFG = ROOT / "data" / "deepseek_config.example.json"


def _ssl_context() -> ssl.SSLContext:
    """Mac 官方 Python 常缺根证书；优先用 certifi，避免 CERTIFICATE_VERIFY_FAILED。"""
    try:
        import certifi  # type: ignore

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()

SYSTEM_PROMPT = """你是黄金(XAUUSD) 5 分钟方向判断。EA 只负责开仓，多空只听你的，不会自己改方向。
止盈、止损、开仓时段全部是用户在 EA 里设好的（快照 USER_TP、USER_SL、OPEN_START、OPEN_END）。
你不能改这些，不要输出止盈、止损或交易时段，也不要把支撑压力当成止盈止损。

方向看这一串已经收盘的 5 分钟 K 线。正在走的那根不算，也不要只看最后一根。
- 信心 72 到 100 才是趋势。5 分钟高点在抬、低点也在抬：DIR=UP。高点在降、低点也在降：DIR=DOWN。30 分钟还没跟上，也不能把这个趋势改成震荡
- 信心在 50 到 71：这是震荡，DIR=FLAT。区间最高点、最低点用最近 10 根已收盘 5 分钟的最高价和最低价。上沿、均价上面、RSI 上涨无力才做空。下沿、均价下面、RSI 下跌无力才做多。不要用 30 分钟决定多空。少一件就写等
- 信心低于 50：不开仓，DIR=FLAT，CONF 写 50 以下
- 只有这串 5 分钟高低点还叠在一起、来回扫，才把趋势写成震荡
- 5 分钟的下针、上针、纺锤只说明这一下有没有拒绝。纺锤是犹豫，不能把它写成趋势反转
- 你只判断整段是上涨、下跌还是震荡。正在创新高不是买点，正在创新低不是卖点
- 出现单根很长的 5 分钟，或这几根已经拉出很长一段还停在尽头：先观望。DIR=FLAT，CONF 写 50 以下，不要追这条长线
- 快照里有「上次判断」时，对照现在的价格。方向被打回来，WHY_TREND 开头写上次错在哪。看错了不要把这根锁成观望，按上面的规则重新判断
- 最后一根收阴或收阳，不能单独把这一串还在上涨的 K 线改成下跌，也不能把还在下跌的改成上涨
- 大起大落之前，先看前面几根已收盘 5 分钟是不是差不多高、差不多低。差不多，而这根正在走的 K 线打破那一簇：跌破做空，突破做多。这是进场时机，不要等它走完再找回撤
- 复盘要写出上次为什么在那个价位开单。同样的位置先看回调，不要立刻再开。不要把方向锁死，也不要因此整段不下单
- 支撑位上先不要空，等回调走出来。回调收盘又掉下来、价格已经离开支撑，才做空。压力位上先不要多，等回调走出来再决定。不是取消这笔单
不要用 MACD、ADX、RSI、随机指标决定方向。震荡不要用 LEAN 假装有趋势。

点位：
- 支撑偏「近端快回调」：近 10～20 根摆动低点/前低
- 压力偏近端摆动高点/前高（上涨时 RES1 尤其要给准）
- 别给离谱远价

只能输出纯键值行（不要 markdown、不要编号、不要其它废话），格式严格如下：
DIR=UP或DOWN或LEAN_UP或LEAN_DOWN或FLAT
CONF=0到100整数
FREEZE=0或1
SHORT=不超过18字中文短因且不要逗号
SUP1=最近支撑价数字
SUP2=次近支撑价数字没有就写0
RES1=最近压力价数字没有就写0
STEP_HINT=建议间距美金仅参考数字
WHY_TREND=40到90字：5分钟高低点是抬高、降低、突破还是来回。信心到72写趋势。50到71写最近10根5分钟的最高最低，以及现价在上沿还是下沿。不要用30分钟决定多空。不要只写最后一根
WHY_SUP=40到90字：支撑为何在SUP1；若偏多/上涨可顺便点出压力RES1含义
LESSON=不超过36字课堂总结

规则：
- FREEZE 默认0；仅 SIDE_MAX>=50 且继续加仓风险极大时才1。FREEZE=1 时 EA 不会开仓也不会加仓
- DIR=UP 且 CONF>=72 才是趋势做多，DIR=DOWN 且 CONF>=72 才是趋势做空
- CONF 在 50 到 71 是震荡。区间用最近 10 根 5 分钟的最高和最低。上沿且在均价上、RSI 上涨无力才做空。下沿且在均价下、RSI 下跌无力才做多。少一件不做。不要用 30 分钟决定多空
- CONF 低于 50，EA 不开仓
- 价位必须贴近快照里的高低点，不要瞎编。这些价位只是说明，不是止盈止损
- 原因用中文，WHY/LESSON 里不要出现英文逗号以外的英文标点干扰解析；可用中文逗号、顿号"""


def _key_usable(data: dict) -> bool:
    key = str(data.get("api_key", "")).strip()
    return bool(key) and key != "YOUR_DEEPSEEK_API_KEY"


def _decode_text(raw: bytes) -> str:
    for enc in ("utf-8-sig", "utf-8", "utf-16", "gbk"):
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode("utf-8", errors="ignore")


def _extract_key(text: str) -> str:
    text = (
        text.replace("\ufeff", "")
        .replace("“", "\"")
        .replace("”", "\"")
        .replace("‘", "'")
        .replace("’", "'")
    )
    m = re.search(r"sk-[A-Za-z0-9_\-]{8,}", text)
    if m:
        return m.group(0).strip()
    m = re.search(r'"api_key"\s*:\s*"([^"]+)"', text)
    if m:
        return m.group(1).strip()
    return ""


def _read_json(path: Path) -> dict:
    raw = path.read_bytes()
    text = _decode_text(raw)
    data: dict = {}
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            data = parsed
    except Exception:
        data = {}
    found = _extract_key(text)
    if found and found != "YOUR_DEEPSEEK_API_KEY":
        data["api_key"] = found
    if not data:
        raise ValueError(f"无法读取 {path.name}")
    return data


def resolve_config(path: Path) -> Path:
    """网页改密钥不会生成文件。兼容：改了模板、记事本存成 UTF-16，或存成 .json.txt。"""
    candidates = [
        path,
        Path(str(path) + ".txt"),
        path.parent / "deepseek_config.json.txt",
        path.parent / "deepseek_config.example.json",
        path.parent / "deepseek_config.example.json.txt",
    ]
    seen: list[Path] = []
    for c in candidates:
        if c not in seen:
            seen.append(c)
    saw_placeholder = False
    broken: list[str] = []
    for c in seen:
        if not c.is_file():
            continue
        try:
            data = _read_json(c)
        except Exception:
            broken.append(c.name)
            continue
        if _key_usable(data):
            if c.resolve() != path.resolve():
                print(f"使用配置 {c}")
            return c
        saw_placeholder = True
    names = "(目录不存在)"
    if path.parent.is_dir():
        names = "、".join(p.name for p in sorted(path.parent.iterdir())) or "(空)"
    if saw_placeholder:
        raise FileNotFoundError(
            "配置文件在，但这台电脑里的 api_key 还是模板 YOUR_DEEPSEEK_API_KEY。\n"
            f"请用记事本打开 {path}\n"
            "把 YOUR_DEEPSEEK_API_KEY 换成你自己的密钥（一般 sk- 开头），保存后再双击打开AI。\n"
            "其他电脑正常，是因为那边这个文件里已经换成了真实密钥。网页上改密钥不会改这个文件。"
        )
    extra = f"\n这些文件打不开: {'、'.join(broken)}" if broken else ""
    raise FileNotFoundError(
        "没有可用的配置文件。\n"
        f"程序要读: {path}\n"
        f"这个目录里现在是: {names}{extra}\n"
        "请把 deepseek_config.example.json 复制为 deepseek_config.json，再写入你的密钥。"
    )


def load_config(path: Path) -> dict:
    path = resolve_config(path)
    data = _read_json(path)
    if not _key_usable(data):
        raise ValueError(f"请在 {path} 里填写有效的 DeepSeek api_key")
    return data


def _windows_terminal_roots() -> list[Path]:
    roots: list[Path] = []
    appdata = os.environ.get("APPDATA", "").strip()
    programdata = os.environ.get("PROGRAMDATA", r"C:\ProgramData").strip()
    if appdata:
        roots.append(Path(appdata) / "MetaQuotes" / "Terminal")
    if programdata:
        roots.append(Path(programdata) / "MetaQuotes" / "Terminal")
    return roots


def common_files_candidates() -> list[Path]:
    """EA 用 FILE_COMMON 写 ai\\snapshot.txt。桥必须盯同一个 Common\\Files。"""
    home = Path.home()
    found: list[Path] = []

    def add(p: Path) -> None:
        try:
            rp = p.resolve() if p.exists() else p
        except OSError:
            rp = p
        if rp not in found:
            found.append(rp)

    appdata = os.environ.get("APPDATA", "").strip()
    if appdata:
        add(Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files")
    add(home / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files")
    add(home / "MT5_Shared_Common" / "Files")
    cx_root = home / "Library/Application Support/CrossOver/Bottles"
    if cx_root.is_dir():
        for bottle in sorted(cx_root.iterdir()):
            for user in ("crossover", "user"):
                add(
                    bottle
                    / "drive_c/users"
                    / user
                    / "AppData/Roaming/MetaQuotes/Terminal/Common/Files"
                )
    add(
        home
        / "Library/Application Support/net.metaquotes.wine.metatrader5"
        / "drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
    )
    return found


def ai_dir_candidates() -> list[Path]:
    """Windows 的公共目录有时在用户 AppData，有时在 ProgramData。以 EA 写下的路径为准。"""
    found: list[Path] = []

    def add(p: Path) -> None:
        if p not in found:
            found.append(p)

    for root in _windows_terminal_roots():
        if not root.is_dir():
            continue
        add(root / "Common" / "Files" / "ai")
        try:
            markers = list(root.glob("*/MQL5/Files/ea_ai_dir.txt"))
            snaps = list(root.glob("*/MQL5/Files/ai/snapshot.txt"))
        except OSError:
            markers, snaps = [], []
        for marker in markers:
            try:
                line = marker.read_text(encoding="utf-8", errors="ignore").strip().splitlines()
            except OSError:
                continue
            if line and line[0].strip():
                add(Path(line[0].strip()))
        for snap in snaps:
            add(snap.parent)
    for files in common_files_candidates():
        add(files / "ai")
    return found


def resolve_ai_dir(configured: str = "") -> Path:
    """优先用已经有 snapshot.txt 的目录；否则用 EA 报告的公共目录。"""
    if configured:
        p = Path(configured)
        return p if p.name.lower() == "ai" else (p / "ai")
    best: Path | None = None
    best_m = -1.0
    fallback: Path | None = None
    candidates = ai_dir_candidates()
    for ai in candidates:
        snap = ai / "snapshot.txt"
        if snap.is_file():
            try:
                m = snap.stat().st_mtime
            except OSError:
                continue
            if m > best_m:
                best, best_m = ai, m
        elif ai.parent.is_dir() and fallback is None:
            fallback = ai
    if best is not None:
        return best
    if fallback is not None:
        return fallback
    return candidates[0] if candidates else (Path.home() / "AppData/Roaming/MetaQuotes/Terminal/Common/Files/ai")


def read_snapshot(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def _swing_hints(snap: dict[str, str]) -> str:
    lows: list[float] = []
    highs: list[float] = []
    for i in range(1, 21):
        try:
            if f"L{i}" in snap:
                lows.append(float(snap[f"L{i}"]))
            if f"H{i}" in snap:
                highs.append(float(snap[f"H{i}"]))
        except ValueError:
            pass
    parts: list[str] = []
    if lows:
        uniq = sorted(set(round(x, 2) for x in lows))[:6]
        parts.append("近端低点参考: " + ", ".join(f"{x:.2f}" for x in uniq[:4]))
        parts.append(f"最低L={min(lows):.2f}")
    if highs:
        parts.append(f"最高H={max(highs):.2f}")
    return "；".join(parts)


def _overall_structure(snap: dict[str, str]) -> str:
    """用近端、远端各约 10 根已收盘 5 分钟 K 线概括走势。C1/H1 是最新一根。不用 30 分钟覆盖。"""

    def nums(prefix: str, start: int, end: int) -> list[float]:
        out: list[float] = []
        for i in range(start, end + 1):
            raw = snap.get(f"{prefix}{i}")
            if not raw:
                continue
            try:
                out.append(float(raw))
            except ValueError:
                continue
        return out

    hp, lp, cp = ("H", "L", "C")
    new_h, old_h = nums(hp, 1, 10), nums(hp, 11, 20)
    new_l, old_l = nums(lp, 1, 10), nums(lp, 11, 20)
    closes = nums(cp, 1, 20)
    if len(new_h) < 3 or len(old_h) < 3 or len(new_l) < 3 or len(old_l) < 3 or len(closes) < 10:
        return ""
    nh, oh = max(new_h), max(old_h)
    nl, ol = min(new_l), min(old_l)
    net = closes[0] - closes[-1]
    last = closes[0]
    if nh > oh and nl > ol:
        struct = "整体抬高"
    elif nh < oh and nl < ol:
        struct = "整体走低"
    elif last > oh and net > 0:
        struct = "突破上行"
    elif last < ol and net < 0:
        struct = "跌破下行"
    else:
        struct = "高低点来回"
    return (
        f"整体结构={struct} 近10根高点={nh:.2f} 前10根高点={oh:.2f} "
        f"近10根低点={nl:.2f} 前10根低点={ol:.2f} 20根收盘变化={net:+.2f}。"
        "这是5分钟K线。信心到72才是趋势，不要用30分钟把趋势改掉"
    )


def _m30_structure(snap: dict[str, str]) -> str:
    """震荡做哪一边，看已收盘的 30 分钟高低点。"""

    def nums(prefix: str, start: int, end: int) -> list[float]:
        out: list[float] = []
        for i in range(start, end + 1):
            raw = snap.get(f"M30{prefix}{i}")
            if not raw:
                continue
            try:
                out.append(float(raw))
            except ValueError:
                continue
        return out

    highs, lows = nums("H", 1, 10), nums("L", 1, 10)
    if len(highs) < 6 or len(lows) < 6:
        return ""
    hi, lo = max(highs), min(lows)
    span = hi - lo
    bid = _num(snap, "BID")
    place = "中间"
    if bid is not None and span > 0:
        pos = (bid - lo) / span
        if pos >= 0.75:
            place = "靠近最高点"
        elif pos <= 0.25:
            place = "靠近最低点"
    return (
        f"30分钟更大范围最高={hi:.2f} 最低={lo:.2f} 现价{place}。"
        "不要用30分钟决定多空。震荡区间用最近10根5分钟的最高和最低。"
    )


def _num(snap: dict[str, str], key: str) -> float | None:
    raw = snap.get(key)
    if raw is None or str(raw).strip() == "":
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _long_line_note(snap: dict[str, str]) -> str:
    """单根振幅很大，或近端已经拉出一段还停在尽头。告诉模型先观望。"""
    ranges: list[float] = []
    for i in range(1, 10):
        hi = _num(snap, f"H{i}")
        lo = _num(snap, f"L{i}")
        if hi is None or lo is None or hi <= lo:
            continue
        ranges.append(hi - lo)
    notes: list[str] = []
    if ranges:
        last = ranges[0]
        prev = ranges[1:]
        avg = sum(prev) / len(prev) if prev else 0.0
        if last >= 8.0 or (last >= 6.0 and avg > 0.0 and last >= avg * 1.8):
            notes.append(
                f"最新已收盘5分钟振幅{last:.1f}美元，前面平均{avg:.1f}美元。"
                "这是长线，先观望，DIR=FLAT，CONF写50以下，不要追。"
            )
    closes: list[float] = []
    for i in range(1, 6):
        c = _num(snap, f"C{i}")
        if c is not None and c > 0:
            closes.append(c)
    if len(closes) >= 5:
        c1 = closes[0]
        stretch = abs(c1 - closes[4])
        if stretch >= 8.0 and (c1 >= max(closes) - 0.01 or c1 <= min(closes) + 0.01):
            notes.append(
                f"近5根收盘走出{stretch:.1f}美元，最新收盘还在这段尽头。"
                "长线先观望，不要在尽头进场。"
            )
    return " ".join(notes)


def load_prev_call(ai_dir: Path) -> dict[str, str]:
    path = ai_dir / "prev_call.txt"
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip().upper()] = v.strip()
    return out


def review_last_call(prev: dict[str, str], snap: dict[str, str]) -> str:
    """把上次方向和之后的价格摆给模型，让它自己写错在哪。"""
    if not prev or "DIR" not in prev:
        return ""
    bid = _num(snap, "BID")
    old = _num(prev, "BID")
    if bid is None or old is None:
        return ""
    d = prev.get("DIR", "").upper()
    move = bid - old
    head = (
        f"上次判断：{d} 信心{prev.get('CONF', '')} 价{old:.2f} "
        f"理由{prev.get('SHORT', '')}。现在价{bid:.2f}，变动{move:+.1f}美元。"
    )
    if d in ("UP", "LEAN_UP") and move <= -2.0:
        return head + "上次看多被打回来。复盘要写这次为什么会在这个价位看多。同样位置先看回调，方向不要锁死。"
    if d in ("DOWN", "LEAN_DOWN") and move >= 2.0:
        return head + "上次看空被打回来。复盘要写这次为什么会在这个价位看空。同样位置先看回调，方向不要锁死。"
    if d in ("UP", "LEAN_UP", "DOWN", "LEAN_DOWN"):
        return head + "上次方向还没被打回来。仍然要区间、均价和RSI一起对上才算震荡单。"
    return head + "上次是观望。这根按区间、均价和RSI重新判断，不要因为上次观望就继续锁住。"


def wrong_dir(prev: dict[str, str], snap: dict[str, str]) -> str:
    if not prev or "DIR" not in prev:
        return ""
    bid = _num(snap, "BID")
    old = _num(prev, "BID")
    if bid is None or old is None:
        return ""
    d = prev.get("DIR", "").upper()
    move = bid - old
    if d in ("UP", "LEAN_UP") and move <= -2.0:
        return "UP"
    if d in ("DOWN", "LEAN_DOWN") and move >= 2.0:
        return "DOWN"
    return ""


def load_last_entry(ai_dir: Path) -> dict[str, str]:
    path = ai_dir / "last_entry.txt"
    if not path.exists():
        return {}
    raw = path.read_bytes()
    text = raw.decode("utf-16", errors="ignore") if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else raw.decode("utf-8", errors="ignore")
    out: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip().upper()] = v.strip()
    return out


def remember_lesson(ai_dir: Path, prev: dict[str, str], snap: dict[str, str]) -> None:
    """复盘记的是上次为什么在那个价位开，不是把方向锁死。"""
    entry = load_last_entry(ai_dir)
    bid = _num(snap, "BID")
    bad = wrong_dir(prev, snap)
    against = False
    if entry and bid is not None:
        try:
            px = float(entry.get("PRICE", "") or "nan")
        except ValueError:
            px = None
        side = entry.get("SIDE", "").upper()
        if px is not None and side == "SELL" and bid >= px + 2.0:
            against = True
        if px is not None and side == "BUY" and bid <= px - 2.0:
            against = True
    if not bad and not against:
        return
    where = entry.get("PRICE", prev.get("BID", ""))
    why = entry.get("WHY", "")
    if not why:
        why = "看多被打回" if bad == "UP" else "看空被打回"
    side_cn = "空" if entry.get("SIDE", "").upper() == "SELL" or bad == "DOWN" else "多"
    body = (
        f"LESSON=上次在{where}开{side_cn}，原因是{why}。"
        "同样的位置不要立刻再开，先看回调走势。方向不要锁死。\n"
    )
    try:
        write_unicode(ai_dir / "lesson.txt", body)
        print(f"复盘: {body.strip()}")
    except OSError as exc:
        print(f"复盘没记下: {exc}")


def lesson_text(ai_dir: Path) -> str:
    path = ai_dir / "lesson.txt"
    if not path.exists():
        return ""
    raw = path.read_bytes()
    text = raw.decode("utf-16", errors="ignore") if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else raw.decode("utf-8", errors="ignore")
    for line in text.splitlines():
        if line.strip().upper().startswith("LESSON="):
            return line.split("=", 1)[1].strip()
    return ""


def save_prev_call(ai_dir: Path, teach: dict[str, str], bid: str) -> None:
    if not str(bid).strip():
        return
    body = "\n".join([
        f"DIR={teach.get('DIR', 'FLAT')}",
        f"CONF={teach.get('CONF', '0')}",
        f"SHORT={teach.get('SHORT', '')}",
        f"BID={bid}",
        f"TIME={time.strftime('%H:%M:%S')}",
    ]) + "\n"
    try:
        (ai_dir / "prev_call.txt").write_text(body, encoding="utf-8")
    except OSError as exc:
        print(f"上次判断没记下: {exc}")


def snapshot_prompt(snap: dict[str, str]) -> str:
    if not snap:
        return "暂无行情快照。请输出中性教学键值：DIR=FLAT CONF=50 FREEZE=0 SHORT=无行情数据 SUP1=0 SUP2=0 RES1=0 STEP_HINT=1 WHY_TREND=暂无数据无法判断趋势 WHY_SUP=暂无数据无法标支撑 LESSON=等EA写出快照再教"
    keys = [
        "SYMBOL", "TIME", "TF", "BID", "ASK", "SPREAD",
        "BUY_N", "SELL_N", "BUY_LOT", "SELL_LOT",
        "BUY_P", "SELL_P", "ALL_P", "SIDE_MAX", "ADX", "RSI",
        "RANGE_2H", "SPREAD_MAX_2H",
        "MA_TF", "M1_BAR", "M5_BAR", "EMA5", "EMA10", "EMA20", "EMA5_PREV", "MA_STATE",
        "K_STATE", "K_BULL", "K_BEAR", "CLOSE_VS_EMA5", "AVG3", "LAST_DIR", "DIR_HINT", "CONFIRM",
        "MACD", "MACD_SIG", "STOCH_K", "STOCH_D", "OSC_STATE", "TREND_STATE",
        "USER_TP", "USER_SL", "OPEN_START", "OPEN_END", "TP_SL_SESSION",
    ]
    lines = ["当前黄金快照。止盈、止损、开仓时段是用户设定，不要改，也不要在回答里写新的止盈止损。请看整段已收盘5分钟，不要只看最后一根："]
    overall = _overall_structure(snap)
    if overall:
        lines.append(overall)
    m30 = _m30_structure(snap)
    if m30:
        lines.append(m30)
    review = snap.get("REVIEW", "").strip()
    if review:
        lines.append(review)
    mistake = snap.get("MISTAKE", "").strip()
    if mistake:
        lines.append(mistake)
    long_note = _long_line_note(snap)
    if long_note:
        lines.append(long_note)
    for k in keys:
        if k in snap:
            lines.append(f"{k}={snap[k]}")
    hist = [f"C{i}={snap[f'C{i}']}" for i in range(1, 21) if f"C{i}" in snap]
    if hist:
        lines.append("已收盘5分钟收盘: " + " ".join(hist))
    m1bars = []
    for i in range(1, 6):
        ck = f"M1C{i}" if f"M1C{i}" in snap else f"M5C{i}"
        if ck in snap:
            ok = ck.replace("C", "O")
            hk = ck.replace("C", "H")
            lk = ck.replace("C", "L")
            m1bars.append(
                f"O{i}={snap.get(ok, '')} C{i}={snap[ck]} H{i}={snap.get(hk, '')} L{i}={snap.get(lk, '')}"
            )
    if m1bars:
        lines.append("最近5根已收盘5分钟: " + " | ".join(m1bars))
    hl = []
    for i in range(1, 11):
        if f"H{i}" in snap and f"L{i}" in snap:
            hl.append(f"H{i}={snap[f'H{i}']} L{i}={snap[f'L{i}']}")
    if hl:
        lines.append("近10高低: " + " | ".join(hl))
    hint = _swing_hints(snap)
    if hint:
        lines.append("程序摆动提示(可锚定支撑): " + hint)
    lines.append("请严格按 SYSTEM 要求输出键值行，重点写清 WHY_TREND 与 WHY_SUP。")
    return "\n".join(lines)


def call_deepseek(cfg: dict, user_content: str) -> str:
    url = cfg.get("base_url", "https://api.deepseek.com/chat/completions").rstrip("/")
    if not url.endswith("/chat/completions"):
        url = url + "/chat/completions"
    primary = str(cfg.get("model", "deepseek-v4-pro"))
    fallback = str(cfg.get("fallback_model", "deepseek-v4-pro")).strip() or "deepseek-v4-pro"
    models = [primary] + ([fallback] if fallback != primary else [])
    timeout = float(cfg.get("timeout_sec", 90))
    retries = max(1, int(cfg.get("api_retries", 3)))
    retry_sleep = float(cfg.get("api_retry_sleep_sec", 2))
    last_err: Exception | None = None
    # 教学桥要固定键值输出：默认关闭思考，避免 token 全耗在 CoT 上导致面板空白
    thinking_on = bool(cfg.get("thinking", False))
    for model in models:
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
            ],
            "temperature": float(cfg.get("temperature", 0.2)),
            "max_tokens": int(cfg.get("max_tokens", 1024)),
            "thinking": {"type": "enabled" if thinking_on else "disabled"},
        }
        body = json.dumps(payload).encode("utf-8")
        for attempt in range(1, retries + 1):
            req = urllib.request.Request(
                url,
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {cfg['api_key']}",
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                msg = data["choices"][0]["message"]
                # 只用最终 content；不要拿 reasoning_content 当答案（会解析失败变「暂无说明」）
                text = (msg.get("content") or "").strip()
                if not text:
                    raise RuntimeError("模型 content 为空（若开了思考请加大 max_tokens 或设 thinking=false）")
                if model != primary:
                    print(f"[API] 已用备用模型 {model}")
                return text
            except urllib.error.HTTPError as e:
                last_err = e
                body_err = e.read().decode("utf-8", errors="ignore")
                print(f"[API] HTTP {e.code} 第{attempt}/{retries}: {body_err[:160]}")
                if e.code not in (429, 500, 502, 503, 504) or attempt >= retries:
                    break
                time.sleep(retry_sleep * attempt)
            except Exception as e:
                last_err = e
                print(f"[API] 第{attempt}/{retries}次失败 ({e}), {retry_sleep:.0f}s后重试...")
                if attempt >= retries:
                    break
                time.sleep(retry_sleep * attempt)
        if model != models[-1]:
            print(f"[API] 主模型失败，切换备用 {fallback}")
    raise RuntimeError(f"DeepSeek 调用失败: {last_err}")


_VALID_DIR = {"UP", "DOWN", "LEAN_UP", "LEAN_DOWN", "FLAT"}


def _clean_cn(s: str, max_len: int) -> str:
    s = s.strip().replace(",", "，").replace("\n", " ").replace("\r", " ")
    s = re.sub(r"\s+", " ", s)
    return s[:max_len]


def parse_teach(raw: str) -> dict[str, str]:
    text = raw.strip()
    text = re.sub(r"```.*?```", "", text, flags=re.S).strip()
    kv: dict[str, str] = {}
    # 先按行解析；再从整段用正则捞 DIR=/WHY_TREND= 等（防模型夹杂废话）
    keys = (
        "DIR", "CONF", "FREEZE", "SHORT", "SUP1", "SUP2", "RES1",
        "STEP_HINT", "WHY_TREND", "WHY_SUP", "LESSON", "M1_BAR", "M5_BAR",
    )
    for line in text.splitlines():
        line = line.strip().strip("`").strip()
        if not line or "=" not in line:
            continue
        line = re.sub(r"^[-*]\s*", "", line)
        k, v = line.split("=", 1)
        k = k.strip().upper()
        v = v.strip()
        if k in keys:
            kv[k] = v
    for k in keys:
        if k in kv:
            continue
        m = re.search(rf"(?im)^\s*{k}\s*=\s*(.+)$", text)
        if m:
            kv[k] = m.group(1).strip()

    # 兼容旧单行 DIR,CONF,FREEZE,reason
    if "DIR" not in kv:
        for line in text.splitlines():
            line = line.strip()
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 3 and parts[0].upper().replace(" ", "_") in _VALID_DIR:
                kv["DIR"] = parts[0].upper().replace(" ", "_")
                kv["CONF"] = parts[1]
                kv["FREEZE"] = parts[2]
                if len(parts) >= 4:
                    kv["SHORT"] = parts[3]
                break

    d = str(kv.get("DIR", "FLAT")).upper().replace(" ", "_")
    alias = {
        "BUY": "UP", "LONG": "UP", "SELL": "DOWN", "SHORT": "DOWN",
        "偏多": "LEAN_UP", "偏空": "LEAN_DOWN", "中性偏多": "LEAN_UP",
        "中性偏空": "LEAN_DOWN", "中性": "FLAT", "NEUTRAL": "FLAT",
    }
    d = alias.get(d, d)
    if d not in _VALID_DIR:
        d = "FLAT"
    try:
        conf = max(0, min(100, int(float(kv.get("CONF", "40")))))
    except ValueError:
        conf = 40
    freeze = "1" if str(kv.get("FREEZE", "0")).strip() in ("1", "true", "True", "YES") else "0"

    def fnum(key: str, default: str = "0") -> str:
        try:
            return f"{float(kv.get(key, default)):.2f}"
        except ValueError:
            return "0.00"

    return {
        "DIR": d,
        "CONF": str(conf),
        "FREEZE": freeze,
        "SHORT": _clean_cn(kv.get("SHORT", "DeepSeek辅助"), 18),
        "SUP1": fnum("SUP1"),
        "SUP2": fnum("SUP2"),
        "RES1": fnum("RES1"),
        "STEP_HINT": fnum("STEP_HINT", "1"),
        "WHY_TREND": _clean_cn(kv.get("WHY_TREND", "暂无趋势说明"), 120),
        "WHY_SUP": _clean_cn(kv.get("WHY_SUP", "暂无支撑说明"), 120),
        "LESSON": _clean_cn(kv.get("LESSON", "方向仅供开仓，止盈止损用用户参数"), 40),
        "M1_BAR": str(kv.get("M1_BAR", kv.get("M5_BAR", ""))).strip(),
        "M5_BAR": str(kv.get("M5_BAR", "")).strip(),
    }


def teach_to_signal_line(t: dict[str, str]) -> str:
    return f"{t['DIR']},{t['CONF']},{t['FREEZE']},{t['SHORT']}"


def teach_to_file_text(t: dict[str, str]) -> str:
    order = [
        "DIR", "CONF", "FREEZE", "SHORT",
        "SUP1", "SUP2", "RES1", "STEP_HINT",
        "WHY_TREND", "WHY_SUP", "LESSON", "M1_BAR",
    ]
    return "\n".join(f"{k}={t[k]}" for k in order) + "\n"


def write_unicode(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    # UTF-16 LE + BOM，匹配 MQL5 FILE_UNICODE
    path.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-16")
    return path


_alive_dir: Path | None = None


def mark_alive(ai_dir: Path, on: bool) -> None:
    """EA 靠这个文件判断 AI 窗口还在不在。关窗口就写成 OFF，EA 不再自动下单。"""
    global _alive_dir
    _alive_dir = ai_dir
    try:
        write_unicode(ai_dir / "alive.txt", "ON\n" if on else "OFF\n")
    except OSError as exc:
        print(f"心跳写入失败: {exc}")


def _stop_alive(signum=None, _frame=None):
    if _alive_dir is not None:
        try:
            write_unicode(_alive_dir / "alive.txt", "OFF\n")
        except OSError:
            pass
    if signum is not None:
        raise SystemExit(0)


atexit.register(_stop_alive)
# Windows 没有 SIGHUP。关掉控制台窗口时用 SIGBREAK。
for _name in ("SIGINT", "SIGTERM", "SIGHUP", "SIGBREAK"):
    _sig = getattr(signal, _name, None)
    if _sig is None:
        continue
    try:
        signal.signal(_sig, _stop_alive)
    except (ValueError, OSError):
        pass


def last_committed_dir(ai_dir: Path) -> str:
    path = ai_dir / "teach.txt"
    if not path.exists():
        return "无"
    raw = path.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        text = raw.decode("utf-16", errors="ignore")
    else:
        text = raw.decode("utf-8", errors="ignore")
    for line in text.splitlines():
        if line.strip().upper().startswith("DIR="):
            d = line.split("=", 1)[1].strip().upper()
            if d in ("UP", "DOWN"):
                return d
    return "无"


def once(cfg: dict, ai_dir: Path, dry_run: bool = False) -> str:
    snap = read_snapshot(ai_dir / "snapshot.txt")
    prev = load_prev_call(ai_dir)
    bad = wrong_dir(prev, snap)
    if bad and not dry_run:
        remember_lesson(ai_dir, prev, snap)
    snap["LAST_DIR"] = last_committed_dir(ai_dir)
    snap["REVIEW"] = review_last_call(prev, snap)
    snap["MISTAKE"] = lesson_text(ai_dir)
    bar = (snap.get("M1_BAR") or snap.get("M5_BAR") or "").strip()
    user = snapshot_prompt(snap)
    raw = call_deepseek(cfg, user)
    teach = parse_teach(raw)
    teach["M1_BAR"] = bar
    line = teach_to_signal_line(teach)
    body = teach_to_file_text(teach)
    if dry_run:
        print(f"[dry-run] raw={raw!r}")
        print(f"[dry-run] signal={line}")
        print(f"[dry-run] teach=\n{body}")
        return line
    sp = write_unicode(ai_dir / "signal.txt", line)
    tp = write_unicode(ai_dir / "teach.txt", body)
    save_prev_call(ai_dir, teach, snap.get("BID", ""))
    print(f"{time.strftime('%H:%M:%S')} → {sp.name}: {line}")
    print(f"         {tp.name}: SUP1={teach['SUP1']} | {teach['LESSON']}")
    return line


def main() -> None:
    ap = argparse.ArgumentParser(description="DeepSeek → MT5 ai/signal.txt + teach.txt")
    ap.add_argument("--config", type=Path, default=DEFAULT_CFG)
    ap.add_argument("--out-dir", type=Path, default=None, help="默认 Common/Files/ai")
    ap.add_argument("--interval", type=float, default=None, help="循环秒数，覆盖配置")
    ap.add_argument("--once", action="store_true", help="只跑一次")
    ap.add_argument("--dry-run", action="store_true", help="只打印不写文件")
    ap.add_argument("--manual", metavar="LINE", help="手工写入一行信号后退出")
    args = ap.parse_args()

    if args.manual:
        out = args.out_dir or resolve_ai_dir()
        teach = parse_teach(args.manual)
        line = teach_to_signal_line(teach)
        if not args.dry_run:
            p = write_unicode(out / "signal.txt", line)
            write_unicode(out / "teach.txt", teach_to_file_text(teach))
            print(f"已写入 {p}: {line}")
        else:
            print(line)
        return

    try:
        cfg = load_config(args.config)
    except (FileNotFoundError, ValueError) as e:
        print(str(e), file=sys.stderr)
        if not EXAMPLE_CFG.exists():
            print("缺少 example 配置文件", file=sys.stderr)
        raise SystemExit(1)

    configured_out = ""
    if args.out_dir is not None:
        configured_out = str(args.out_dir)
    else:
        configured_out = str(cfg.get("out_dir", "") or "").strip()

    interval = args.interval if args.interval is not None else float(cfg.get("interval_sec", 40))

    if args.once or args.dry_run:
        ai_dir = resolve_ai_dir(configured_out)
        try:
            once(cfg, ai_dir, dry_run=args.dry_run)
        except urllib.error.HTTPError as e:
            print(f"API HTTP {e.code}: {e.read().decode('utf-8', errors='ignore')}", file=sys.stderr)
            raise SystemExit(2)
        except Exception as e:
            print(f"失败: {e}", file=sys.stderr)
            raise SystemExit(2)
        return

    print("写出 signal.txt + teach.txt。这个窗口关了，EA 就不再自动下单。")
    print("止盈、止损、开仓时段用 EA 里你设的参数，不采用模型价位。")
    print("每 40 秒问一次。不到50不开仓。50到71看最近10根5分钟、均价和RSI。不看30分钟方向。72才做趋势。")
    while True:
        ai_dir = resolve_ai_dir(configured_out)
        mark_alive(ai_dir, True)
        try:
            snap_path = ai_dir / "snapshot.txt"
            if not snap_path.exists():
                print(f"{time.strftime('%H:%M:%S')} 等待 EA 快照")
                print(f"    正在看: {snap_path}")
                print("    Windows 请确认这是 MT5「文件 → 打开公共数据文件夹」里的 ai")
                print("    专家日志里应有一行「AI快照目录」。没有这行就是图上还没挂上 6.97。")
            else:
                age = time.time() - snap_path.stat().st_mtime
                if age > 180:
                    print(f"{time.strftime('%H:%M:%S')} 快照已 {int(age)} 秒没更新: {snap_path}")
                once(cfg, ai_dir, dry_run=False)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="ignore")
            print(f"API HTTP {e.code}: {body[:200]}")
        except Exception as e:
            print(f"本轮失败: {e}")
        time.sleep(max(5.0, interval))


if __name__ == "__main__":
    main()

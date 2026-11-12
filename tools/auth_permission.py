# -*- coding: utf-8 -*-
"""权限落盘：写入授权令牌到 MT5 公共目录，供多个终端共用。"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path


def app_dir() -> Path:
    """程序目录：开发时为 tools/；打包成 exe 后为 exe 所在目录（可写）。"""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def resource_dir() -> Path:
    """只读资源目录（图标等）；PyInstaller onefile 在 _MEIPASS。"""
    if getattr(sys, "frozen", False):
        meipass = getattr(sys, "_MEIPASS", None)
        if meipass:
            return Path(meipass)
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


ROOT = app_dir()
DATA_DIR = ROOT / "data"
CLIENT_CONFIG = DATA_DIR / "client_config.json"


def default_common_licenses_dir() -> Path:
    appdata = os.environ.get("APPDATA", "")
    if appdata:
        p = Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files" / "licenses"
        return p
    return ROOT.parent / "licenses"


def _admin_config_path() -> Path:
    return DATA_DIR / "config.json"


def read_admin_client_server_url() -> str | None:
    """从后台 config.json 读取给客户端用的固定服务器地址。"""
    path = _admin_config_path()
    if not path.exists():
        return None
    try:
        admin = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    url = str(admin.get("client_server_url") or "").strip()
    if url:
        return url.rstrip("/")
    port = int(admin.get("server_port") or 8787)
    return f"http://127.0.0.1:{port}"


def sync_client_config_from_admin(admin_cfg: dict | None = None) -> dict:
    """
    后台 → 窗口联动：把 config.json 的 client_server_url
    写入 client_config.json，授权窗口只读此文件。
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    default_dir = str(default_common_licenses_dir())

    if admin_cfg is None:
        path = _admin_config_path()
        if path.exists():
            try:
                admin_cfg = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                admin_cfg = {}
        else:
            admin_cfg = {}

    port = int(admin_cfg.get("server_port") or 8787)
    server_url = str(admin_cfg.get("client_server_url") or "").strip().rstrip("/")
    if not server_url:
        server_url = f"http://127.0.0.1:{port}"

    hb = int(admin_cfg.get("heartbeat_seconds") or 30)
    out_dir = str(admin_cfg.get("license_output_dir") or default_dir)

    if CLIENT_CONFIG.exists():
        try:
            cfg = json.loads(CLIENT_CONFIG.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            cfg = {}
    else:
        cfg = {}

    cfg["server_url"] = server_url
    cfg["permission_dir"] = out_dir or default_dir
    cfg["heartbeat_seconds"] = max(5, hb)
    # 标记来源，方便排查
    cfg["synced_from"] = "admin_config"
    CLIENT_CONFIG.write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return cfg


def load_client_config() -> dict:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    default_dir = str(default_common_licenses_dir())
    # 本机开发时有后台 config 才联动；客户 exe 旁通常没有 admin config
    if _admin_config_path().exists() and not getattr(sys, "frozen", False):
        return sync_client_config_from_admin()

    if not CLIENT_CONFIG.exists():
        CLIENT_CONFIG.write_text(
            json.dumps(
                {
                    "server_url": "http://127.0.0.1:8787",
                    "permission_dir": default_dir,
                    "heartbeat_seconds": 30,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
    cfg = json.loads(CLIENT_CONFIG.read_text(encoding="utf-8"))
    # 若仍指向旧的单机目录，或别人电脑路径，自动改到本机 Common
    old = str(cfg.get("permission_dir", ""))
    old_norm = old.replace("\\", "/").lower()
    need_fix = (
        not old.strip()
        or "xauusd-quant" in old_norm
        or old_norm.endswith("/ea/licenses")
        or ("/appdata/roaming/metaquotes/" in old_norm and "administrator" in old_norm
            and "administrator" not in os.environ.get("USERNAME", "").lower())
    )
    # 打包分发：强制用客户本机 Common，避免写死打包机路径
    if getattr(sys, "frozen", False) and old.replace("\\", "/") != default_dir.replace("\\", "/"):
        need_fix = True
    if need_fix:
        cfg["permission_dir"] = default_dir
        CLIENT_CONFIG.write_text(
            json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    return cfg


def permission_dir(cfg: dict | None = None) -> Path:
    c = cfg or load_client_config()
    raw = str(c.get("permission_dir") or "").strip()
    p = Path(raw) if raw else default_common_licenses_dir()
    p.mkdir(parents=True, exist_ok=True)
    return p


def save_client_server_url(server_url: str) -> dict:
    """保存客户可见的服务器地址（分发 exe 后可改公网 IP）。"""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    cfg = load_client_config()
    url = (server_url or "").strip().rstrip("/")
    if not url:
        raise ValueError("服务器地址不能为空")
    cfg["server_url"] = url
    # 客户机统一写到本机 MT5 Common，避免把你电脑路径打进配置
    cfg["permission_dir"] = str(default_common_licenses_dir())
    CLIENT_CONFIG.write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return cfg


def write_heartbeat(
    account: int,
    username: str,
    expiry: str,
    max_windows: int | None = None,
    mt5_accounts: list[int] | None = None,
) -> None:
    out = permission_dir()
    n = int(max_windows) if max_windows is not None else 1
    if n < 1:
        n = 1
    accounts = [int(a) for a in (mt5_accounts or [])]
    payload = {
        "account": int(account),
        "username": username,
        "expiry": expiry,
        "max_windows": n,
        "mt5_accounts": accounts,
        "updated_at": datetime.now().isoformat(timespec="seconds"),
        "status": "running",
    }
    (out / "service.heartbeat").write_text(
        json.dumps(payload, ensure_ascii=False), encoding="utf-8"
    )
    # 给 EA 读的简洁元数据（窗口上限随绑定账号数增加）
    (out / "service.meta").write_text(
        json.dumps(
            {
                "username": username,
                "expiry": expiry,
                "max_windows": n,
                "mt5_count": len(accounts) if accounts else n,
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )


def save_permission(
    account: int,
    license_key: str,
    username: str,
    expiry: str,
    max_windows: int | None = None,
    mt5_accounts: list[int] | None = None,
) -> Path:
    out = permission_dir()
    path = out / f"{account}.lic"
    path.write_text(license_key.strip() + "\n", encoding="ascii")
    write_heartbeat(account, username, expiry, max_windows, mt5_accounts)
    return path


def save_permissions(
    licenses: list[dict],
    username: str,
    expiry: str,
    max_windows: int | None = None,
) -> list[Path]:
    """一次登录写入多个 MT5 账号的 .lic。licenses 项含 account, license_key"""
    paths: list[Path] = []
    accounts = [int(item["account"]) for item in licenses]
    n = int(max_windows) if max_windows is not None else max(1, len(accounts))
    primary = accounts[0] if accounts else 0
    for item in licenses:
        acc = int(item["account"])
        key = str(item["license_key"])
        out = permission_dir()
        path = out / f"{acc}.lic"
        path.write_text(key.strip() + "\n", encoding="ascii")
        paths.append(path)
    if primary:
        write_heartbeat(primary, username, expiry, n, accounts)
    return paths


def set_autostart(enabled: bool, app_cmd: str) -> None:
    try:
        import winreg
    except ImportError as exc:
        raise RuntimeError("仅支持 Windows 开机自启") from exc
    key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
    name = "EAAuthTool"
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_SET_VALUE) as key:
        if enabled:
            winreg.SetValueEx(key, name, 0, winreg.REG_SZ, app_cmd)
        else:
            try:
                winreg.DeleteValue(key, name)
            except FileNotFoundError:
                pass


def is_autostart_enabled() -> bool:
    try:
        import winreg

        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Run",
            0,
            winreg.KEY_READ,
        ) as key:
            winreg.QueryValueEx(key, "EAAuthTool")
            return True
    except OSError:
        return False


# ---------- 整机 MT5 多开限制（绑几个账号开几个终端进程）----------
_MT5_PROCESS_NAMES = ("terminal64.exe", "terminal.exe")


def default_windows_slot_dir() -> Path:
    return default_common_licenses_dir() / "windows"


def cleanup_stale_window_slots(stale_sec: int = 120) -> int:
    """清掉 EA 关掉后残留的窗口槽位文件，避免「人已关、槽位还占着」。"""
    folder = default_windows_slot_dir()
    if not folder.is_dir():
        return 0
    import time

    now = time.time()
    removed = 0
    for path in folder.glob("*.win"):
        try:
            if now - path.stat().st_mtime > stale_sec:
                path.unlink(missing_ok=True)
                removed += 1
        except OSError:
            pass
    return removed


def count_active_window_slots(stale_sec: int = 120) -> int:
    """与 EA 一致：按 Common\\licenses\\windows\\*.win 计授权占用。"""
    cleanup_stale_window_slots(stale_sec)
    folder = default_windows_slot_dir()
    if not folder.is_dir():
        return 0
    import time

    now = time.time()
    n = 0
    for path in folder.glob("*.win"):
        try:
            if now - path.stat().st_mtime <= stale_sec:
                n += 1
        except OSError:
            continue
    return n


def list_mt5_processes(*, only_visible: bool = True) -> list[dict]:
    """只统计仍有主窗口的 terminal64/terminal（已关窗口残留进程不算）。"""
    import subprocess

    visible_filter = (
        "Where-Object { $_.MainWindowHandle -ne 0 } | " if only_visible else ""
    )
    ps = (
        "$names=@('terminal64','terminal'); "
        "Get-Process -Name $names -ErrorAction SilentlyContinue | "
        f"{visible_filter}"
        "Select-Object Id, ProcessName, StartTime, MainWindowTitle, Path | "
        "ConvertTo-Json -Compress"
    )
    try:
        raw = subprocess.check_output(
            ["powershell", "-NoProfile", "-Command", ps],
            text=True,
            encoding="utf-8",
            errors="ignore",
            timeout=15,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).strip()
    except (subprocess.SubprocessError, OSError):
        return []
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    out: list[dict] = []
    for item in data:
        try:
            pid = int(item.get("Id") or 0)
        except (TypeError, ValueError):
            continue
        if pid <= 0:
            continue
        name = str(item.get("ProcessName") or "")
        if name.lower() not in ("terminal64", "terminal"):
            continue
        out.append(
            {
                "pid": pid,
                "name": name,
                "created": str(item.get("StartTime") or ""),
                "title": str(item.get("MainWindowTitle") or ""),
                "path": str(item.get("Path") or ""),
            }
        )
    out.sort(key=lambda x: x["created"], reverse=True)
    return out


def enforce_mt5_window_limit(max_windows: int) -> list[int]:
    """
    与 EA 对齐：先看授权窗口槽位（*.win）。
    槽位未超限 → 不杀进程（避免关图表/卸 EA 后误杀）。
    槽位与可见进程都超限 → 才结束多余进程。
    """
    import subprocess

    n = max(1, int(max_windows or 1))
    cleanup_stale_window_slots(120)
    slots = count_active_window_slots(120)
    procs = list_mt5_processes(only_visible=True)

    if slots <= n:
        return []
    if len(procs) <= n:
        return []

    to_kill = procs[: max(0, len(procs) - n)]
    killed: list[int] = []
    for p in to_kill:
        pid = p["pid"]
        try:
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/F"],
                check=False,
                capture_output=True,
                timeout=10,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            killed.append(pid)
        except (subprocess.SubprocessError, OSError):
            pass
    return killed


def count_mt5_processes() -> int:
    return len(list_mt5_processes(only_visible=True))


def describe_mt5_limit_state(max_windows: int | None = None) -> str:
    slots = count_active_window_slots(120)
    procs = list_mt5_processes(only_visible=True)
    lines = [
        f"EA窗口槽位(授权占用): {slots}"
        + (f" / 上限{max_windows}" if max_windows else ""),
        f"可见MT5进程: {len(procs)}",
    ]
    for p in procs[:8]:
        title = (p.get("title") or "").strip() or "(无标题)"
        if len(title) > 40:
            title = title[:40] + "..."
        lines.append(f"  PID {p['pid']}  {title}")
    folder = default_windows_slot_dir()
    if folder.is_dir():
        wins = sorted(folder.glob("*.win"))
        if wins:
            lines.append("槽位文件:")
            for w in wins[:8]:
                lines.append(f"  {w.name}")
    return "\n".join(lines)


def describe_mt5_processes() -> str:
    return describe_mt5_limit_state()

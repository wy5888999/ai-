# -*- coding: utf-8 -*-
"""授权核心逻辑（无界面），供 GUI / 命令行共用。"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
USERS_FILE = DATA_DIR / "users.json"
CONFIG_FILE = DATA_DIR / "config.json"
DEFAULT_LIC_DIR = ROOT.parent / "licenses"


def license_hash(text: str) -> int:
    hash_val = 2166136261
    for ch in text:
        hash_val ^= ord(ch)
        hash_val = (hash_val * 16777619) & 0xFFFFFFFF
    return hash_val


def generate_license(account: int, expiry_ymd: str, secret: str) -> str:
    if account <= 0:
        raise ValueError("账号必须是正整数")
    if not re.fullmatch(r"\d{8}", expiry_ymd):
        raise ValueError("到期日格式必须是 YYYYMMDD")
    datetime.strptime(expiry_ymd, "%Y%m%d")
    if not secret or secret == "CHANGE_THIS_SECRET_KEY_2026":
        raise ValueError("请先在 config.json 中设置自定义 license_secret")
    payload = f"{account}|{expiry_ymd}|{secret}"
    checksum = license_hash(payload) % 100000000
    return f"{account}-{expiry_ymd}-{checksum:08d}"


def password_hash(password: str, salt: str) -> str:
    return hashlib.sha256(f"{salt}:{password}".encode("utf-8")).hexdigest()


def ensure_data_files() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_FILE.exists():
        CONFIG_FILE.write_text(
            json.dumps(
                {
                    "license_secret": "CHANGE_THIS_SECRET_KEY_2026",
                    "license_output_dir": str(DEFAULT_LIC_DIR),
                    "heartbeat_seconds": 30,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
    if not USERS_FILE.exists():
        # 示例用户：用户名可用 MT5 账号，密码请登录后尽快改掉
        salt = "xauusd-auth"
        demo_pwd = password_hash("123456", salt)
        USERS_FILE.write_text(
            json.dumps(
                {
                    "salt": salt,
                    "users": [
                        {
                            "username": "3100961",
                            "password_hash": demo_pwd,
                            "mt5_account": 3100961,
                            "expiry": "20260930",
                            "enabled": True,
                        }
                    ],
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )


def load_config() -> dict:
    ensure_data_files()
    return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))


def load_users() -> dict:
    ensure_data_files()
    return json.loads(USERS_FILE.read_text(encoding="utf-8"))


def authenticate(username: str, password: str) -> dict:
    """验证用户名密码，成功返回用户信息字典。"""
    db = load_users()
    salt = db.get("salt", "xauusd-auth")
    pwd_hash = password_hash(password, salt)
    for user in db.get("users", []):
        if str(user.get("username")) != str(username):
            continue
        if not user.get("enabled", True):
            raise ValueError("该用户已禁用")
        if user.get("password_hash") != pwd_hash:
            raise ValueError("密码错误")
        expiry = str(user["expiry"])
        today = datetime.now().strftime("%Y%m%d")
        if today > expiry:
            raise ValueError(f"授权已过期（{expiry[:4]}/{int(expiry[4:6])}/{int(expiry[6:8])}）")
        return user
    raise ValueError("用户名不存在")


def format_expiry_display(expiry_ymd: str) -> str:
    return f"{expiry_ymd[:4]}/{int(expiry_ymd[4:6])}/{int(expiry_ymd[6:8])}"


def issue_license_files(user: dict, config: dict | None = None) -> tuple[str, Path]:
    """签发 .lic 与心跳文件，返回 (授权码, lic路径)。"""
    cfg = config or load_config()
    secret = cfg["license_secret"]
    out_dir = Path(cfg.get("license_output_dir") or DEFAULT_LIC_DIR)
    out_dir.mkdir(parents=True, exist_ok=True)

    account = int(user["mt5_account"])
    expiry = str(user["expiry"])
    key = generate_license(account, expiry, secret)

    lic_path = out_dir / f"{account}.lic"
    lic_path.write_text(key + "\n", encoding="ascii")

    # 心跳：EA 可检查此文件是否在近期更新（表示授权工具服务在跑）
    hb = out_dir / "service.heartbeat"
    hb.write_text(
        json.dumps(
            {
                "account": account,
                "username": user["username"],
                "expiry": expiry,
                "updated_at": datetime.now().isoformat(timespec="seconds"),
                "status": "running",
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    return key, lic_path


def write_heartbeat(user: dict, config: dict | None = None) -> None:
    cfg = config or load_config()
    out_dir = Path(cfg.get("license_output_dir") or DEFAULT_LIC_DIR)
    out_dir.mkdir(parents=True, exist_ok=True)
    hb = out_dir / "service.heartbeat"
    hb.write_text(
        json.dumps(
            {
                "account": int(user["mt5_account"]),
                "username": user["username"],
                "expiry": str(user["expiry"]),
                "updated_at": datetime.now().isoformat(timespec="seconds"),
                "status": "running",
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )


def set_autostart(enabled: bool, app_path: str) -> None:
    """写入/删除当前用户开机启动（注册表 Run）。"""
    try:
        import winreg
    except ImportError as exc:
        raise RuntimeError("仅支持 Windows 开机自启") from exc

    key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
    name = "XAUUSDAuthTool"
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_SET_VALUE) as key:
        if enabled:
            # 用 pythonw 无黑窗启动 GUI
            cmd = f'"{app_path}"'
            winreg.SetValueEx(key, name, 0, winreg.REG_SZ, cmd)
        else:
            try:
                winreg.DeleteValue(key, name)
            except FileNotFoundError:
                pass


def is_autostart_enabled() -> bool:
    try:
        import winreg

        key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_READ) as key:
            winreg.QueryValueEx(key, "XAUUSDAuthTool")
            return True
    except OSError:
        return False

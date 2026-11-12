# -*- coding: utf-8 -*-
"""授权后台数据库：一授权用户可绑定多个 MT5 账号（默认最多 5 个）。"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

from license_core import (
    CONFIG_FILE,
    DATA_DIR,
    DEFAULT_LIC_DIR,
    load_config,
    password_hash,
)

DB_PATH = DATA_DIR / "license.db"
SALT = "xauusd-auth"
MAX_MT5_DEFAULT = 10


def _conn() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def _now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def max_mt5_per_user() -> int:
    cfg = ensure_config()
    return int(cfg.get("max_mt5_per_user", MAX_MT5_DEFAULT))


def init_db() -> None:
    with _conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                mt5_account INTEGER NOT NULL DEFAULT 0,
                expiry TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                note TEXT DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS user_mt5 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL,
                mt5_account INTEGER NOT NULL,
                UNIQUE(username, mt5_account)
            );
            CREATE TABLE IF NOT EXISTS admin (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                username TEXT NOT NULL,
                password_hash TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS login_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT,
                ok INTEGER,
                ip TEXT,
                message TEXT,
                created_at TEXT NOT NULL
            );
            """
        )
        # 迁移：客户密码明文（后台列表可见）
        cols = {
            r[1] for r in conn.execute("PRAGMA table_info(users)").fetchall()
        }
        if "password_plain" not in cols:
            conn.execute(
                "ALTER TABLE users ADD COLUMN password_plain TEXT DEFAULT ''"
            )

        row = conn.execute("SELECT id FROM admin WHERE id=1").fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO admin(id, username, password_hash) VALUES (1, ?, ?)",
                ("admin", password_hash("admin123", SALT)),
            )
        # 迁移：把 users.mt5_account 同步到 user_mt5
        users = conn.execute("SELECT username, mt5_account FROM users").fetchall()
        for u in users:
            if int(u["mt5_account"] or 0) > 0:
                conn.execute(
                    "INSERT OR IGNORE INTO user_mt5(username, mt5_account) VALUES (?, ?)",
                    (u["username"], int(u["mt5_account"])),
                )
        if conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"] == 0:
            expiry = (datetime.now() + timedelta(days=30)).strftime("%Y%m%d")
            conn.execute(
                """
                INSERT INTO users(username, password_hash, password_plain, mt5_account, expiry, enabled, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
                """,
                (
                    "demo",
                    password_hash("123456", SALT),
                    "123456",
                    3100961,
                    expiry,
                    "示例用户",
                    _now(),
                    _now(),
                ),
            )
            conn.execute(
                "INSERT OR IGNORE INTO user_mt5(username, mt5_account) VALUES (?, ?)",
                ("demo", 3100961),
            )


def ensure_config() -> dict:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_FILE.exists():
        import json
        from os import environ

        common = (
            Path(environ.get("APPDATA", ""))
            / "MetaQuotes"
            / "Terminal"
            / "Common"
            / "Files"
            / "licenses"
        )
        CONFIG_FILE.write_text(
            json.dumps(
                {
                    "license_secret": "CHANGE_THIS_SECRET_KEY_2026",
                    "license_output_dir": str(common if common.parent.parent.exists() else DEFAULT_LIC_DIR),
                    "heartbeat_seconds": 30,
                    "server_host": "0.0.0.0",
                    "server_port": 8787,
                    "admin_path": "/admin",
                    "client_server_url": "http://127.0.0.1:8787",
                    "max_mt5_per_user": MAX_MT5_DEFAULT,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
    cfg = load_config()
    if "max_mt5_per_user" not in cfg:
        cfg["max_mt5_per_user"] = MAX_MT5_DEFAULT
    if "client_server_url" not in cfg:
        port = int(cfg.get("server_port") or 8787)
        cfg["client_server_url"] = f"http://127.0.0.1:{port}"
        save_config(cfg)
    return cfg


def save_config(cfg: dict) -> None:
    import json

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    # 联动授权窗口：同步 client_config.json
    try:
        import auth_permission as perm

        perm.sync_client_config_from_admin(cfg)
    except Exception:
        pass


def get_mt5_accounts(username: str) -> list[int]:
    init_db()
    with _conn() as conn:
        rows = conn.execute(
            "SELECT mt5_account FROM user_mt5 WHERE username=? ORDER BY id",
            (username,),
        ).fetchall()
    return [int(r["mt5_account"]) for r in rows]


def _enrich_user(d: dict) -> dict:
    today = datetime.now().strftime("%Y%m%d")
    exp = d["expiry"]
    try:
        left = (datetime.strptime(exp, "%Y%m%d").date() - datetime.now().date()).days
    except ValueError:
        left = -999
    d["days_left"] = left
    d["expired"] = exp < today
    d["expiry_display"] = f"{exp[:4]}/{int(exp[4:6])}/{int(exp[6:8])}"
    accounts = get_mt5_accounts(d["username"])
    d["mt5_accounts"] = accounts
    d["mt5_accounts_display"] = "、".join(str(a) for a in accounts) if accounts else "-"
    d["mt5_count"] = len(accounts)
    d["mt5_max"] = max_mt5_per_user()
    if accounts:
        d["mt5_account"] = accounts[0]
    plain = str(d.get("password_plain") or "").strip()
    d["password_display"] = plain if plain else "（未存明文，请重设）"
    return d


def list_users() -> list[dict]:
    init_db()
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM users ORDER BY expiry ASC, id ASC"
        ).fetchall()
    return [_enrich_user(dict(r)) for r in rows]


def get_user(username: str) -> dict | None:
    init_db()
    with _conn() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE username=?", (username,)
        ).fetchone()
    if not row:
        return None
    return _enrich_user(dict(row))


def _parse_accounts(raw: str | list | int) -> list[int]:
    if isinstance(raw, int):
        return [raw] if raw > 0 else []
    if isinstance(raw, list):
        out = []
        for x in raw:
            try:
                n = int(x)
                if n > 0:
                    out.append(n)
            except (TypeError, ValueError):
                pass
        return out
    text = str(raw or "").replace("，", ",").replace(" ", ",").replace("\n", ",")
    out = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            n = int(part)
            if n > 0:
                out.append(n)
        except ValueError as exc:
            raise ValueError(f"无效的MT5账号: {part}") from exc
    # 去重保序
    seen = set()
    uniq = []
    for n in out:
        if n not in seen:
            seen.add(n)
            uniq.append(n)
    return uniq


def create_user(
    username: str,
    password: str,
    mt5_account: int | str | list = 0,
    months: int = 1,
    note: str = "",
    mt5_accounts: str | list | None = None,
) -> dict:
    init_db()
    username = username.strip()
    if not username:
        raise ValueError("用户名不能为空")
    accounts = _parse_accounts(mt5_accounts if mt5_accounts is not None else mt5_account)
    if not accounts:
        raise ValueError("请至少填写 1 个 MT5 账号")
    limit = max_mt5_per_user()
    if len(accounts) > limit:
        raise ValueError(f"每个授权用户最多绑定 {limit} 个 MT5 账号")
    if months < 1:
        months = 1
    expiry = (datetime.now() + timedelta(days=30 * months)).strftime("%Y%m%d")
    with _conn() as conn:
        try:
            conn.execute(
                """
                INSERT INTO users(username, password_hash, password_plain, mt5_account, expiry, enabled, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
                """,
                (
                    username,
                    password_hash(password, SALT),
                    password,
                    int(accounts[0]),
                    expiry,
                    note,
                    _now(),
                    _now(),
                ),
            )
        except sqlite3.IntegrityError as exc:
            raise ValueError("用户名已存在") from exc
        for acc in accounts:
            conn.execute(
                "INSERT OR IGNORE INTO user_mt5(username, mt5_account) VALUES (?, ?)",
                (username, acc),
            )
    return get_user(username)  # type: ignore


def add_mt5_account(username: str, mt5_account: int) -> dict:
    init_db()
    user = get_user(username)
    if not user:
        raise ValueError("用户不存在")
    mt5_account = int(mt5_account)
    if mt5_account <= 0:
        raise ValueError("MT5账号无效")
    cur = get_mt5_accounts(username)
    if mt5_account in cur:
        raise ValueError("该 MT5 账号已绑定")
    if len(cur) >= max_mt5_per_user():
        raise ValueError(f"已达上限：每个授权用户最多 {max_mt5_per_user()} 个 MT5")
    with _conn() as conn:
        conn.execute(
            "INSERT INTO user_mt5(username, mt5_account) VALUES (?, ?)",
            (username, mt5_account),
        )
        if int(user.get("mt5_account") or 0) <= 0:
            conn.execute(
                "UPDATE users SET mt5_account=?, updated_at=? WHERE username=?",
                (mt5_account, _now(), username),
            )
        else:
            conn.execute(
                "UPDATE users SET updated_at=? WHERE username=?",
                (_now(), username),
            )
    return get_user(username)  # type: ignore


def remove_mt5_account(username: str, mt5_account: int) -> dict:
    init_db()
    user = get_user(username)
    if not user:
        raise ValueError("用户不存在")
    mt5_account = int(mt5_account)
    cur = get_mt5_accounts(username)
    if mt5_account not in cur:
        raise ValueError("未绑定该 MT5 账号")
    if len(cur) <= 1:
        raise ValueError("至少保留 1 个 MT5 账号，无法解绑")
    with _conn() as conn:
        conn.execute(
            "DELETE FROM user_mt5 WHERE username=? AND mt5_account=?",
            (username, mt5_account),
        )
        left = [
            int(r["mt5_account"])
            for r in conn.execute(
                "SELECT mt5_account FROM user_mt5 WHERE username=? ORDER BY id",
                (username,),
            ).fetchall()
        ]
        conn.execute(
            "UPDATE users SET mt5_account=?, updated_at=? WHERE username=?",
            (left[0], _now(), username),
        )
    return get_user(username)  # type: ignore


def renew_user(username: str, months: int = 1) -> dict:
    init_db()
    user = get_user(username)
    if not user:
        raise ValueError("用户不存在")
    if months < 1:
        months = 1
    today = datetime.now().date()
    try:
        cur = datetime.strptime(user["expiry"], "%Y%m%d").date()
    except ValueError:
        cur = today
    base = cur if cur > today else today
    new_exp = (base + timedelta(days=30 * months)).strftime("%Y%m%d")
    with _conn() as conn:
        conn.execute(
            "UPDATE users SET expiry=?, updated_at=?, enabled=1 WHERE username=?",
            (new_exp, _now(), username),
        )
    return get_user(username)  # type: ignore


def set_enabled(username: str, enabled: bool) -> dict:
    init_db()
    with _conn() as conn:
        conn.execute(
            "UPDATE users SET enabled=?, updated_at=? WHERE username=?",
            (1 if enabled else 0, _now(), username),
        )
    user = get_user(username)
    if not user:
        raise ValueError("用户不存在")
    return user


def set_password(username: str, password: str) -> None:
    init_db()
    with _conn() as conn:
        cur = conn.execute(
            "UPDATE users SET password_hash=?, password_plain=?, updated_at=? WHERE username=?",
            (password_hash(password, SALT), password, _now(), username),
        )
        if cur.rowcount == 0:
            raise ValueError("用户不存在")


def change_password_by_user(username: str, old_password: str, new_password: str) -> None:
    """客户前台自助改密：校验旧密码后写入新密码（含明文供后台可见）。"""
    init_db()
    username = username.strip()
    if not username:
        raise ValueError("用户名不能为空")
    if not new_password or len(new_password) < 4:
        raise ValueError("新密码至少 4 位")
    if old_password == new_password:
        raise ValueError("新密码不能与旧密码相同")
    user = get_user(username)
    if not user:
        raise ValueError("用户名不存在")
    if not user["enabled"]:
        raise ValueError("账号已禁用")
    if user["password_hash"] != password_hash(old_password, SALT):
        raise ValueError("原密码错误")
    set_password(username, new_password)


def verify_admin(username: str, password: str) -> bool:
    init_db()
    with _conn() as conn:
        row = conn.execute("SELECT * FROM admin WHERE id=1").fetchone()
    if not row:
        return False
    return row["username"] == username and row["password_hash"] == password_hash(
        password, SALT
    )


def authenticate_client(username: str, password: str) -> dict:
    init_db()
    user = get_user(username)
    if not user:
        raise ValueError("用户名不存在")
    if not user["enabled"]:
        raise ValueError("账号已禁用，请联系管理员续费")
    if user["password_hash"] != password_hash(password, SALT):
        raise ValueError("密码错误")
    today = datetime.now().strftime("%Y%m%d")
    if user["expiry"] < today:
        raise ValueError(
            f"已过期（{user['expiry'][:4]}/{user['expiry'][4:6]}/{user['expiry'][6:8]}），请续费"
        )
    if not user.get("mt5_accounts"):
        raise ValueError("未绑定任何 MT5 账号，请联系管理员")
    return user


def log_login(username: str, ok: bool, ip: str, message: str) -> None:
    init_db()
    with _conn() as conn:
        conn.execute(
            "INSERT INTO login_log(username, ok, ip, message, created_at) VALUES (?,?,?,?,?)",
            (username, 1 if ok else 0, ip, message, _now()),
        )


def recent_logs(limit: int = 50) -> list[dict]:
    init_db()
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM login_log ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]

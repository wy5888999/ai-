#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
授权后台服务（你自己用）

功能:
  - 网页后台：看客户到期、开户、按月续费、禁用
  - API：给「用户窗口」登录校验

启动:
  pip install flask
  python admin_server.py

后台地址: http://127.0.0.1:8787/admin
默认管理员: admin / admin123

给别人的窗口连: http://你的公网IP或内网IP:8787
"""

from __future__ import annotations

import sys
from functools import wraps
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from flask import (
        Flask,
        flash,
        get_flashed_messages,
        jsonify,
        redirect,
        render_template,
        request,
        session,
        url_for,
    )
except ImportError:
    print("请先安装: pip install flask")
    raise SystemExit(1)

import license_core as core
import license_db as db

ROOT = Path(__file__).resolve().parent
app = Flask(__name__, template_folder=str(ROOT / "templates"))
app.secret_key = "change-me-admin-secret-key-2026"


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get("admin_ok"):
            return redirect(url_for("admin_login"))
        return fn(*args, **kwargs)

    return wrapper


@app.route("/")
def index():
    return redirect(url_for("admin_home"))


@app.route("/admin/login", methods=["GET", "POST"])
def admin_login():
    error = None
    if request.method == "POST":
        u = request.form.get("username", "").strip()
        p = request.form.get("password", "")
        if db.verify_admin(u, p):
            session["admin_ok"] = True
            session["admin_user"] = u
            return redirect(url_for("admin_home"))
        error = "账号或密码错误"
    return render_template("admin_login.html", error=error)


@app.route("/admin/logout")
def admin_logout():
    session.clear()
    return redirect(url_for("admin_login"))


@app.route("/admin")
@login_required
def admin_home():
    msgs = get_flashed_messages(with_categories=True)
    flash_text = ""
    flash_err = False
    if msgs:
        flash_err = msgs[0][0] == "error"
        flash_text = msgs[0][1]
    cfg = db.ensure_config()
    return render_template(
        "admin.html",
        users=db.list_users(),
        flash=flash_text,
        flash_err=flash_err,
        client_server_url=cfg.get("client_server_url", "http://127.0.0.1:8787"),
        server_port=int(cfg.get("server_port", 8787)),
        max_mt5_per_user=int(cfg.get("max_mt5_per_user", 10)),
    )


@app.route("/admin/settings", methods=["POST"])
@login_required
def admin_settings():
    """固定授权窗口连哪个服务器，并写入 client_config 联动。"""
    try:
        cfg = db.ensure_config()
        url = (request.form.get("client_server_url") or "").strip().rstrip("/")
        if not url:
            raise ValueError("服务器地址不能为空")
        if not (url.startswith("http://") or url.startswith("https://")):
            raise ValueError("地址需以 http:// 或 https:// 开头")
        cfg["client_server_url"] = url
        db.save_config(cfg)
        flash(f"已保存并联动授权窗口：{url}", "ok")
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/create", methods=["POST"])
@login_required
def admin_create():
    try:
        # 支持多个 MT5：逗号分隔，或沿用单字段
        raw = request.form.get("mt5_accounts") or request.form.get("mt5_account", "")
        db.create_user(
            username=request.form.get("username", ""),
            password=request.form.get("password", ""),
            mt5_accounts=raw,
            months=int(request.form.get("months", "1") or "1"),
            note=request.form.get("note", ""),
        )
        flash("开户成功", "ok")
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/mt5/add", methods=["POST"])
@login_required
def admin_mt5_add():
    try:
        db.add_mt5_account(
            request.form.get("username", "").strip(),
            int(request.form.get("mt5_account", "0")),
        )
        flash("已绑定 MT5 账号", "ok")
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/mt5/remove", methods=["POST"])
@login_required
def admin_mt5_remove():
    try:
        db.remove_mt5_account(
            request.form.get("username", "").strip(),
            int(request.form.get("mt5_account", "0")),
        )
        flash("已解绑 MT5 账号", "ok")
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/renew", methods=["POST"])
@login_required
def admin_renew():
    try:
        username = request.form.get("username", "")
        months = int(request.form.get("months", "1") or "1")
        user = db.renew_user(username, months=months)
        flash(
            f"{username} 已续费 {months} 个月，新到期日 {user['expiry'][:4]}/{user['expiry'][4:6]}/{user['expiry'][6:8]}",
            "ok",
        )
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/disable", methods=["POST"])
@login_required
def admin_disable():
    try:
        db.set_enabled(request.form.get("username", ""), False)
        flash("已禁用", "ok")
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/password", methods=["POST"])
@login_required
def admin_password():
    try:
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        if not password or len(password) < 4:
            raise ValueError("新密码至少 4 位")
        db.set_password(username, password)
        flash(f"已修改 {username} 的密码", "ok")
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/enable", methods=["POST"])
@login_required
def admin_enable():
    try:
        db.set_enabled(request.form.get("username", ""), True)
        flash("已启用", "ok")
    except Exception as exc:
        flash(str(exc), "error")
    return redirect(url_for("admin_home"))


@app.route("/admin/logs")
@login_required
def admin_logs():
    return render_template("admin_logs.html", logs=db.recent_logs(100))


# ---------------- 给用户窗口的 API ----------------
@app.route("/api/login", methods=["POST"])
def api_login():
    data = request.get_json(silent=True) or {}
    username = str(data.get("username", "")).strip()
    password = str(data.get("password", ""))
    ip = request.headers.get("X-Forwarded-For", request.remote_addr or "")
    try:
        user = db.authenticate_client(username, password)
        cfg = db.ensure_config()
        accounts = user.get("mt5_accounts") or []
        licenses = []
        for acc in accounts:
            key = core.generate_license(int(acc), user["expiry"], cfg["license_secret"])
            licenses.append({"account": int(acc), "license_key": key})
        db.log_login(username, True, ip, f"login ok, mt5={len(licenses)}")
        exp = user["expiry"]
        max_windows = max(1, len(accounts))
        return jsonify(
            {
                "ok": True,
                "username": user["username"],
                "mt5_account": int(accounts[0]) if accounts else 0,
                "mt5_accounts": [int(a) for a in accounts],
                "max_windows": max_windows,
                "licenses": licenses,
                "license_key": licenses[0]["license_key"] if licenses else "",
                "expiry": user["expiry"],
                "expiry_display": f"{exp[:4]}/{int(exp[4:6])}/{int(exp[6:8])}",
                "days_left": (
                    __import__("datetime").datetime.strptime(exp, "%Y%m%d").date()
                    - __import__("datetime").datetime.now().date()
                ).days,
            }
        )
    except Exception as exc:
        db.log_login(username, False, ip, str(exc))
        return jsonify({"ok": False, "error": str(exc)}), 401


@app.route("/api/health")
def api_health():
    return jsonify({"ok": True, "service": "ea-license-admin"})


@app.route("/api/change_password", methods=["POST"])
def api_change_password():
    """授权前台登录后自助修改密码。"""
    data = request.get_json(silent=True) or {}
    username = str(data.get("username", "")).strip()
    old_password = str(data.get("old_password", ""))
    new_password = str(data.get("new_password", ""))
    ip = request.headers.get("X-Forwarded-For", request.remote_addr or "")
    try:
        db.change_password_by_user(username, old_password, new_password)
        db.log_login(username, True, ip, "change password ok")
        return jsonify({"ok": True, "message": "密码已修改"})
    except Exception as exc:
        db.log_login(username, False, ip, f"change password: {exc}")
        return jsonify({"ok": False, "error": str(exc)}), 400


def main() -> None:
    db.init_db()
    cfg = db.ensure_config()
    # 启动时同步固定服务器地址到授权窗口配置
    db.save_config(cfg)
    host = cfg.get("server_host", "0.0.0.0")
    port = int(cfg.get("server_port", 8787))
    client_url = cfg.get("client_server_url", f"http://127.0.0.1:{port}")
    print("=" * 50)
    print("授权后台已启动（支持一用户绑定多个 MT5）")
    print(f"  管理页面: http://127.0.0.1:{port}/admin")
    print(f"  授权窗口固定连: {client_url}")
    print(f"  每用户最多 MT5: {cfg.get('max_mt5_per_user', 10)}")
    print("  默认管理员: admin / admin123")
    print("=" * 50)
    app.run(host=host, port=port, debug=False)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
授权工具（用户端）——只做权限：登录、验权、显示有效期、维持授权服务。

运行: python auth_gui.py
"""

from __future__ import annotations

import json
import os
import sys
import threading
import traceback
import tkinter as tk
import urllib.error
import urllib.request
from pathlib import Path
from tkinter import messagebox

sys.path.insert(0, str(Path(__file__).resolve().parent if not getattr(sys, "frozen", False) else Path(sys.executable).resolve().parent))
import auth_permission as perm

# 对齐原版授权工具观感：米色底、清晰字、不花哨
BG = "#F5E6C8"
FG = "#222222"
BTN_FG = "#8B5A2B"
OK_FG = "#1B8A3E"
ERR_FG = "#B00020"
LINK_FG = "#1E6BB8"
ENTRY_BG = "#FFFFFF"

FONT = ("Microsoft YaHei UI", 12)
FONT_SM = ("Microsoft YaHei UI", 11)
FONT_BTN = ("Microsoft YaHei UI", 12)


def api_login(server_url: str, username: str, password: str) -> dict:
    url = server_url.rstrip("/") + "/api/login"
    body = json.dumps({"username": username, "password": password}).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="ignore")
        try:
            data = json.loads(raw)
            raise ValueError(data.get("error") or raw) from exc
        except json.JSONDecodeError as e2:
            raise ValueError(f"服务器错误 HTTP {exc.code}") from e2
    except urllib.error.URLError as exc:
        raise ValueError(f"连不上授权服务器：{exc.reason}") from exc


def api_change_password(
    server_url: str, username: str, old_password: str, new_password: str
) -> dict:
    url = server_url.rstrip("/") + "/api/change_password"
    body = json.dumps(
        {
            "username": username,
            "old_password": old_password,
            "new_password": new_password,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="ignore")
        try:
            data = json.loads(raw)
            raise ValueError(data.get("error") or raw) from exc
        except json.JSONDecodeError as e2:
            raise ValueError(f"服务器错误 HTTP {exc.code}") from e2
    except urllib.error.URLError as exc:
        raise ValueError(f"连不上授权服务器：{exc.reason}") from exc


class AuthApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("授权工具")
        self.configure(bg=BG)
        self.minsize(380, 360)
        self.geometry("420x380")
        self.resizable(False, False)
        self._set_window_icon()

        cfg = perm.load_client_config()
        self.server_url = str(cfg.get("server_url") or "http://127.0.0.1:8787").rstrip("/")
        self._session: dict | None = None
        self._hb_stop = threading.Event()
        self._hb_running = False
        self._guard_stop = threading.Event()
        self._guard_running = False
        self._tray = None
        self._ready = False
        self._last_kill_tip = 0.0

        self._build_ui()
        try:
            self._autostart_var.set(perm.is_autostart_enabled())
        except Exception:
            self._autostart_var.set(False)

        self.protocol("WM_DELETE_WINDOW", self._on_close_click)
        self.after(300, self._mark_ready)
        self.after(50, self._center_window)

    def _center_window(self) -> None:
        self.update_idletasks()
        w, h = self.winfo_width(), self.winfo_height()
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        self.geometry(f"+{(sw - w) // 2}+{(sh - h) // 3}")

    def _set_window_icon(self) -> None:
        ico = perm.resource_dir() / "assets" / "auth.ico"
        if not ico.exists():
            ico = perm.app_dir() / "assets" / "auth.ico"
        if not ico.exists():
            return
        try:
            self.iconbitmap(default=str(ico))
        except Exception:
            try:
                self.iconbitmap(str(ico))
            except Exception:
                pass

    def _mark_ready(self) -> None:
        self._ready = True

    def _build_ui(self) -> None:
        form = tk.Frame(self, bg=BG)
        form.pack(expand=True, fill="both", padx=36, pady=(28, 8))

        r0 = tk.Frame(form, bg=BG)
        r0.pack(fill="x", pady=8)
        tk.Label(r0, text="服务器", bg=BG, fg=FG, font=FONT, width=6, anchor="e").pack(
            side="left", padx=(0, 10)
        )
        self.entry_server = tk.Entry(
            r0,
            font=FONT_SM,
            bg=ENTRY_BG,
            fg=FG,
            relief="solid",
            bd=1,
            highlightthickness=0,
            insertbackground=FG,
        )
        self.entry_server.pack(side="left", fill="x", expand=True, ipady=3)
        self.entry_server.insert(0, self.server_url)

        r1 = tk.Frame(form, bg=BG)
        r1.pack(fill="x", pady=8)
        tk.Label(r1, text="用户名", bg=BG, fg=FG, font=FONT, width=6, anchor="e").pack(
            side="left", padx=(0, 10)
        )
        self.entry_user = tk.Entry(
            r1,
            font=FONT,
            bg=ENTRY_BG,
            fg=FG,
            relief="solid",
            bd=1,
            highlightthickness=0,
            insertbackground=FG,
        )
        self.entry_user.pack(side="left", fill="x", expand=True, ipady=3)

        r2 = tk.Frame(form, bg=BG)
        r2.pack(fill="x", pady=8)
        tk.Label(r2, text="密  码", bg=BG, fg=FG, font=FONT, width=6, anchor="e").pack(
            side="left", padx=(0, 10)
        )
        self.entry_pwd = tk.Entry(
            r2,
            show="*",
            font=FONT,
            bg=ENTRY_BG,
            fg=FG,
            relief="solid",
            bd=1,
            highlightthickness=0,
            insertbackground=FG,
        )
        self.entry_pwd.pack(side="left", fill="x", expand=True, ipady=3)

        btns = tk.Frame(form, bg=BG)
        btns.pack(pady=(18, 6))
        self.btn_login = tk.Button(
            btns,
            text="登录",
            width=8,
            font=FONT_BTN,
            fg=BTN_FG,
            bg="#EFE6D6",
            activebackground="#E4D8C0",
            activeforeground=BTN_FG,
            relief="raised",
            bd=2,
            cursor="hand2",
            command=self._on_login,
        )
        self.btn_login.pack(side="left", padx=14)
        tk.Button(
            btns,
            text="退出",
            width=8,
            font=FONT_BTN,
            fg=FG,
            bg="#EFE6D6",
            activebackground="#E4D8C0",
            relief="raised",
            bd=2,
            cursor="hand2",
            command=self._quit,
        ).pack(side="left", padx=14)

        # 登录后才可用：修改密码 / 切换账号
        self.after_login = tk.Frame(form, bg=BG)
        self.link_chg = tk.Label(
            self.after_login,
            text="修改密码",
            bg=BG,
            fg=LINK_FG,
            font=FONT_SM,
            cursor="hand2",
        )
        self.link_chg.pack(side="left", padx=(0, 16))
        self.link_chg.bind("<Button-1>", lambda _e: self._open_change_password())
        self.link_switch = tk.Label(
            self.after_login,
            text="切换账号",
            bg=BG,
            fg=LINK_FG,
            font=FONT_SM,
            cursor="hand2",
        )
        self.link_switch.pack(side="left")
        self.link_switch.bind("<Button-1>", lambda _e: self._switch_account())
        # 先不显示，登录成功后再 pack

        self.status = tk.Label(
            self,
            text="请登录",
            bg=BG,
            fg=FG,
            font=FONT_SM,
            wraplength=360,
            justify="center",
        )
        self.status.pack(pady=(4, 8), fill="x", padx=20)

        foot = tk.Frame(self, bg=BG)
        foot.pack(fill="x", side="bottom", padx=18, pady=(0, 14))

        self._autostart_var = tk.BooleanVar(value=False)
        tk.Checkbutton(
            foot,
            text="开机自启动",
            variable=self._autostart_var,
            bg=BG,
            fg=LINK_FG,
            activebackground=BG,
            activeforeground=LINK_FG,
            selectcolor=BG,
            font=FONT_SM,
            highlightthickness=0,
            bd=0,
            command=self._toggle_autostart,
        ).pack(side="left")

        tray = tk.Frame(foot, bg=BG, cursor="hand2")
        tray.pack(side="right")
        key = tk.Canvas(tray, width=18, height=18, bg=BG, highlightthickness=0)
        key.pack(side="left", padx=(0, 4))
        key.create_oval(2, 2, 10, 10, outline=LINK_FG, width=2)
        key.create_line(10, 6, 16, 6, fill=LINK_FG, width=2)
        key.create_line(14, 6, 14, 10, fill=LINK_FG, width=2)
        tray_lbl = tk.Label(
            tray, text="最小化到托盘", bg=BG, fg=LINK_FG, font=FONT_SM, cursor="hand2"
        )
        tray_lbl.pack(side="left")
        for w in (tray, key, tray_lbl):
            w.bind("<Button-1>", lambda _e: self._hide_to_tray())

        self.entry_pwd.bind("<Return>", lambda _e: self._on_login())
        self.entry_user.bind("<Return>", lambda _e: self.entry_pwd.focus_set())

    def _resolve_server(self) -> str:
        """优先用窗口里填的地址，并写回本地配置。"""
        typed = ""
        try:
            typed = self.entry_server.get().strip().rstrip("/")
        except Exception:
            typed = ""
        if typed:
            try:
                perm.save_client_server_url(typed)
            except Exception:
                pass
            self.server_url = typed
            return self.server_url
        cfg = perm.load_client_config()
        url = str(cfg.get("server_url") or self.server_url).strip().rstrip("/")
        self.server_url = url or self.server_url
        return self.server_url

    def _set_status(self, text: str, ok: bool = True) -> None:
        self.status.config(text=text, fg=OK_FG if ok else ERR_FG)

    def _on_login(self) -> None:
        user = self.entry_user.get().strip()
        pwd = self.entry_pwd.get()
        server = self._resolve_server()
        try:
            data = api_login(server, user, pwd)
            if not data.get("ok"):
                raise ValueError(data.get("error") or "登录失败")
            key = data.get("license_key") or ""
            licenses = data.get("licenses") or []
            if licenses:
                max_win = int(data.get("max_windows") or len(licenses))
                paths = perm.save_permissions(
                    licenses,
                    data["username"],
                    str(data["expiry"]),
                    max_windows=max_win,
                )
                n = len(paths)
            else:
                if not key:
                    raise ValueError("服务器未返回授权令牌")
                account = int(data["mt5_account"])
                max_win = int(data.get("max_windows") or 1)
                perm.save_permission(
                    account,
                    key,
                    data["username"],
                    str(data["expiry"]),
                    max_windows=max_win,
                    mt5_accounts=[account],
                )
                n = 1
            accounts = data.get("mt5_accounts") or [data.get("mt5_account")]
            self._session = {
                "account": int(accounts[0]) if accounts else int(data["mt5_account"]),
                "username": data["username"],
                "expiry": str(data["expiry"]),
                "accounts": [int(a) for a in accounts],
                "max_windows": int(data.get("max_windows") or n),
                "password": pwd,
            }
            self._start_keepalive()
            self._start_mt5_guard()
            exp_show = data.get("expiry_display") or data["expiry"]
            win_n = self._session["max_windows"]
            acc_show = "、".join(str(a) for a in self._session["accounts"])
            self._set_status(
                f"服务运行成功，用户有效期：{exp_show}\n"
                f"已绑 {n} 个MT5，整机最多开 {win_n} 个MT5\n"
                f"（多开会被自动关闭）\n{acc_show}",
                ok=True,
            )
            self.entry_user.config(state="disabled")
            self.entry_pwd.config(state="disabled")
            self.entry_server.config(state="disabled")
            self.btn_login.config(state="disabled")
            if not self.after_login.winfo_ismapped():
                self.after_login.pack(pady=(4, 2))
        except Exception as exc:
            self._set_status(str(exc), ok=False)

    def _switch_account(self) -> None:
        """解锁输入框，可改账号重新登录。"""
        self._stop_keepalive()
        self._stop_mt5_guard()
        self._hb_running = False
        self._session = None
        self.entry_user.config(state="normal")
        self.entry_pwd.config(state="normal")
        self.entry_server.config(state="normal")
        self.btn_login.config(state="normal")
        self.entry_pwd.delete(0, "end")
        if self.after_login.winfo_ismapped():
            self.after_login.pack_forget()
        self._set_status("请登录", ok=True)
        self.status.config(fg=FG)

    def _open_change_password(self) -> None:
        if not self._session:
            messagebox.showinfo("修改密码", "请先登录")
            return

        win = tk.Toplevel(self)
        win.title("修改密码")
        win.configure(bg=BG)
        win.resizable(False, False)
        win.transient(self)
        win.grab_set()
        win.geometry("360x220")

        body = tk.Frame(win, bg=BG)
        body.pack(fill="both", expand=True, padx=24, pady=16)

        def row(label: str, show: str = "") -> tk.Entry:
            fr = tk.Frame(body, bg=BG)
            fr.pack(fill="x", pady=6)
            tk.Label(fr, text=label, bg=BG, fg=FG, font=FONT_SM, width=8, anchor="e").pack(
                side="left", padx=(0, 8)
            )
            e = tk.Entry(
                fr,
                font=FONT,
                bg=ENTRY_BG,
                relief="solid",
                bd=1,
                show=show,
                insertbackground=FG,
            )
            e.pack(side="left", fill="x", expand=True, ipady=2)
            return e

        e_old = row("原密码", "*")
        e_new = row("新密码", "*")
        e_confirm = row("确认新密", "*")
        # 原密码默认填当前登录密码，仍可改
        e_old.insert(0, str(self._session.get("password") or ""))
        e_new.focus_set()

        tip = tk.Label(body, text="", bg=BG, fg=ERR_FG, font=("Microsoft YaHei UI", 9))
        tip.pack(fill="x", pady=(4, 0))

        def submit() -> None:
            old_p = e_old.get()
            new_p = e_new.get()
            conf = e_confirm.get()
            if new_p != conf:
                tip.config(text="两次新密码不一致")
                return
            try:
                data = api_change_password(
                    self._resolve_server(),
                    self._session["username"],
                    old_p,
                    new_p,
                )
                if not data.get("ok"):
                    raise ValueError(data.get("error") or "修改失败")
                self._session["password"] = new_p
                self.entry_pwd.config(state="normal")
                self.entry_pwd.delete(0, "end")
                self.entry_pwd.insert(0, new_p)
                self.entry_pwd.config(state="disabled")
                win.destroy()
                messagebox.showinfo("修改密码", "密码已修改成功")
            except Exception as exc:
                tip.config(text=str(exc))

        bf = tk.Frame(body, bg=BG)
        bf.pack(pady=(12, 0))
        tk.Button(
            bf,
            text="确定",
            width=8,
            font=FONT_BTN,
            fg=BTN_FG,
            bg="#EFE6D6",
            command=submit,
        ).pack(side="left", padx=8)
        tk.Button(
            bf, text="取消", width=8, font=FONT_BTN, bg="#EFE6D6", command=win.destroy
        ).pack(side="left", padx=8)
        win.bind("<Return>", lambda _e: submit())

    def _start_mt5_guard(self) -> None:
        """登录后监控：以 EA 窗口槽位为准，槽位超限且进程也超才关终端。"""
        if self._guard_running or not self._session:
            return
        self._guard_running = True
        self._guard_stop.clear()
        max_win = max(1, int(self._session.get("max_windows") or 1))

        def loop() -> None:
            over_streak = 0
            while not self._guard_stop.wait(3.0):
                try:
                    perm.cleanup_stale_window_slots(120)
                    slots = perm.count_active_window_slots(120)
                    procs = perm.count_mt5_processes()
                    # 槽位未超 = 授权占用已释放，不算多开
                    if slots <= max_win:
                        over_streak = 0
                        continue
                    if procs <= max_win:
                        over_streak = 0
                        continue
                    over_streak += 1
                    if over_streak < 2:
                        continue
                    over_streak = 0
                    killed = perm.enforce_mt5_window_limit(max_win)
                    if killed:
                        self.after(0, lambda k=len(killed): self._on_mt5_killed(k, max_win))
                except Exception:
                    pass

        threading.Thread(target=loop, daemon=True).start()

    def _stop_mt5_guard(self) -> None:
        self._guard_stop.set()
        self._guard_running = False

    def _on_mt5_killed(self, killed: int, max_win: int) -> None:
        import time

        now = time.time()
        detail = ""
        try:
            detail = "\n\n" + perm.describe_mt5_limit_state(max_win)
        except Exception:
            pass
        if now - self._last_kill_tip < 8:
            self._set_status(
                f"已拦截多开：关掉 {killed} 个MT5（上限 {max_win}）",
                ok=False,
            )
            return
        self._last_kill_tip = now
        slots = perm.count_active_window_slots(120)
        cur = perm.count_mt5_processes()
        self._set_status(
            f"多开拦截：关 {killed} 个 | 槽位 {slots}/{max_win} | 进程 {cur}",
            ok=False,
        )
        try:
            messagebox.showwarning(
                "MT5 多开限制",
                f"当前授权最多 {max_win} 个 EA 窗口槽位。\n"
                f"已自动关闭多余终端。\n\n"
                f"说明：\n"
                f"· 以「授权槽位」为准（挂了授权 EA 的终端）\n"
                f"· 只关图表 ≠ 关掉 MT5；请关整个终端窗口\n"
                f"· 卸掉 EA 后槽位最多残留约 2 分钟\n"
                f"{detail}",
            )
        except Exception:
            pass

    def _start_keepalive(self) -> None:
        if self._hb_running or not self._session:
            return
        self._hb_running = True
        self._hb_stop.clear()
        cfg = perm.load_client_config()
        interval = max(5, int(cfg.get("heartbeat_seconds", 30)))
        s = self._session

        def loop() -> None:
            while not self._hb_stop.wait(interval):
                try:
                    perm.write_heartbeat(
                        s["account"],
                        s["username"],
                        s["expiry"],
                        max_windows=int(s.get("max_windows") or 1),
                        mt5_accounts=s.get("accounts") or [],
                    )
                except Exception:
                    pass

        threading.Thread(target=loop, daemon=True).start()

    def _stop_keepalive(self) -> None:
        self._hb_stop.set()
        self._hb_running = False

    def _toggle_autostart(self) -> None:
        try:
            if getattr(sys, "frozen", False):
                cmd = f'"{Path(sys.executable).resolve()}"'
            else:
                pyw = Path(sys.executable).with_name("pythonw.exe")
                launcher = str(pyw if pyw.exists() else Path(sys.executable))
                cmd = f'"{launcher}" "{Path(__file__).resolve()}"'
            perm.set_autostart(self._autostart_var.get(), cmd)
        except Exception as exc:
            messagebox.showerror("开机自启", str(exc))
            self._autostart_var.set(perm.is_autostart_enabled())

    def _hide_to_tray(self) -> None:
        try:
            import pystray
            from PIL import Image, ImageDraw
        except ImportError:
            self.iconify()
            return

        self.withdraw()
        if self._tray is not None:
            return
        img = Image.new("RGB", (64, 64), LINK_FG)
        d = ImageDraw.Draw(img)
        d.ellipse((14, 14, 34, 34), outline="#F5E6C8", width=4)
        d.line((34, 24, 50, 24), fill="#F5E6C8", width=4)
        d.line((46, 24, 46, 34), fill="#F5E6C8", width=3)
        menu = pystray.Menu(
            pystray.MenuItem("显示窗口", lambda _i, _j: self.after(0, self._restore)),
            pystray.MenuItem("退出", lambda _i, _j: self.after(0, self._quit)),
        )
        self._tray = pystray.Icon("ea_auth", img, "授权工具", menu)
        threading.Thread(target=self._tray.run, daemon=True).start()

    def _on_close_click(self) -> None:
        if messagebox.askyesno("退出", "确定退出授权工具？"):
            self._quit()

    def _restore(self) -> None:
        self.deiconify()
        self.state("normal")
        self.lift()

    def _quit(self) -> None:
        self._stop_keepalive()
        self._stop_mt5_guard()
        if self._tray is not None:
            try:
                self._tray.stop()
            except Exception:
                pass
            self._tray = None
        self.destroy()


FONT = ("Microsoft YaHei UI", 12)
FONT_SM = ("Microsoft YaHei UI", 11)
FONT_BTN = ("Microsoft YaHei UI", 12)

# 单实例：防止同时开多个授权工具
_SINGLE_MUTEX = None
_SINGLE_LOCK_FH = None


def ensure_single_instance() -> bool:
    """
    若已有授权工具在运行，返回 False。
    Windows 用命名互斥体；同时写锁文件作双保险。
    """
    global _SINGLE_MUTEX, _SINGLE_LOCK_FH

    lock_path = perm.app_dir() / "data" / "auth_tool.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    if sys.platform.startswith("win"):
        import ctypes

        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        ERROR_ALREADY_EXISTS = 183
        # 全局互斥，同一用户重复启动会命中
        name = "Local\\EA_AuthTool_SingleInstance_v1"
        handle = kernel32.CreateMutexW(None, False, name)
        last = kernel32.GetLastError()
        if not handle:
            return False
        _SINGLE_MUTEX = handle
        if last == ERROR_ALREADY_EXISTS:
            return False

    # 锁文件：记录 pid，异常退出后下次可覆盖
    try:
        _SINGLE_LOCK_FH = open(lock_path, "a+", encoding="utf-8")
        if sys.platform.startswith("win"):
            import msvcrt

            try:
                msvcrt.locking(_SINGLE_LOCK_FH.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                return False
        else:
            import fcntl

            try:
                fcntl.flock(_SINGLE_LOCK_FH.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return False
        _SINGLE_LOCK_FH.seek(0)
        _SINGLE_LOCK_FH.truncate()
        _SINGLE_LOCK_FH.write(str(os.getpid()))
        _SINGLE_LOCK_FH.flush()
    except OSError:
        # 锁文件失败时，若 Windows 互斥已拿到仍允许运行
        if _SINGLE_MUTEX is None:
            return False

    return True


def _show_already_running() -> None:
    try:
        root = tk.Tk()
        root.withdraw()
        messagebox.showwarning(
            "授权工具",
            "授权工具已经在运行。\n\n"
            "请到任务栏或系统托盘找到已打开的窗口，不要重复启动。",
        )
        root.destroy()
    except Exception:
        print("授权工具已经在运行，请勿重复打开。")


def main() -> None:
    if not ensure_single_instance():
        _show_already_running()
        raise SystemExit(0)
    try:
        app = AuthApp()
        app.mainloop()
    except Exception:
        err = traceback.format_exc()
        try:
            root = tk.Tk()
            root.withdraw()
            messagebox.showerror("授权工具启动失败", err)
            root.destroy()
        except Exception:
            print(err)
            input("按回车退出…")
        raise SystemExit(1)


if __name__ == "__main__":
    main()

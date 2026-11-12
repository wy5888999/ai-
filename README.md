# ai-

一个 deep seek 的黄金 EA。

# XAUUSD 网格 EA + 独立授权工具（窗口版）

授权与交易 **完全分开**：先开「授权工具」登录，再挂 EA。

## 别人那种窗口是怎么做的

截图那类工具本质是：

1. **独立 Windows 程序**（常见 C# WinForms / Python Tkinter，不是写在 `.mq5` 里）
2. 窗口里：用户名、密码、登录/退出、状态文字、开机自启、托盘
3. 登录成功后在本地写授权文件 / 心跳，或连远程服务器校验
4. **EA 只检查结果**（读文件 / 读心跳），自己不做登录界面

本仓库用 **Python + Tkinter** 做了同类窗口：`tools/auth_gui.py`

## 文件分工

| 组件 | 路径 | 职责 |
|------|------|------|
| 授权窗口 | `tools/auth_gui.py` | 登录界面、自启、托盘、心跳 |
| 授权逻辑 | `tools/license_core.py` | 验密、签发 `.lic` |
| 用户数据 | `tools/data/users.json` | 用户名/密码/有效期/绑定 MT5 账号 |
| 配置 | `tools/data/config.json` | `license_secret`、输出目录 |
| EA 校验 | `MQL5/Include/License/AccountLicense.mqh` | 读 `.lic` + 心跳 |
| 网格 EA | `MQL5/Experts/XAUUSD_Grid_EA.mq5` | 只做交易 |

## 快速使用

### 1. 改密钥

- `tools/data/config.json` → `license_secret`
- `MQL5/Include/License/AccountLicense.mqh` → `LICENSE_SECRET`  
两者必须相同。

### 2. 配置用户

编辑 `tools/data/users.json`（首次运行 GUI 会自动生成示例）：

- 默认示例：用户名 `3100961`，密码 `123456`，有效期 `2026/9/30`
- `mt5_account` 必须等于 MT5 登录账号

改密码：用同样 salt 算 SHA256，或临时把密码哈希换成新值后告诉我帮你生成。

### 3. 启动授权窗口

```bash
cd tools
python auth_gui.py
```

托盘图标（可选）：

```bash
pip install pystray pillow
```

登录成功后会显示类似：`服务运行成功，用户有效期：2026/9/30`  
并写出：

- `licenses/<账号>.lic`
- `licenses/service.heartbeat`

把整个 `licenses` 目录复制到 MT5：

`MQL5/Files/licenses/`

（也可把 `config.json` 里 `license_output_dir` 直接指到该路径。）

### 4. 编译并挂 EA

复制 `Include/License` 与 `Experts/XAUUSD_Grid_EA.mq5` 到 MT5 对应目录，F7 编译后挂图。  
**必须先登录授权工具**，否则 EA 会因缺少心跳而拒绝启动。

## 和商业授权工具的差异

| 项目 | 常见商业工具 | 本仓库当前版 |
|------|--------------|--------------|
| 界面 | C# / Delphi 等 | Python Tkinter |
| 校验 | 常连远程服务器 | 本地用户表 + 本地文件 |
| 与 EA | 分离 | 分离（相同思路） |

若要改成「连你自己的网站验证账号」，可在 `auth_gui.py` 登录处改成 HTTP 请求，EA 侧仍只读本地签发结果即可。

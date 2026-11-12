# -*- coding: utf-8 -*-
"""Strengthen DeepSeek bridge against 503/timeout for distributed clients."""
from __future__ import annotations

from pathlib import Path

lib = next(Path(r"C:\Users\Administrator\Desktop\823").rglob("ai_bridge_lib.py"))
# skip data/__pycache__
cands = [
    p
    for p in Path(r"C:\Users\Administrator\Desktop\823").rglob("ai_bridge_lib.py")
    if "__pycache__" not in p.parts and "data" not in p.parts
]
lib = cands[0]
print("LIB:", lib)
text = lib.read_text(encoding="utf-8")

# Find call_deepseek and replace with retry+fallback version
marker = "def call_deepseek("
idx = text.find(marker)
if idx < 0:
    raise SystemExit("call_deepseek not found")

# find next def at same level after call_deepseek
rest = text[idx:]
# end at next \ndef that is not nested - heuristic: \ndef at start of line
import re

m = re.search(r"\ndef (?!_)", rest[4:])  # skip past "def call..."
if not m:
    raise SystemExit("cannot find end of call_deepseek")
end = idx + 4 + m.start()
old_fn = text[idx:end]
print("OLD FN LEN", len(old_fn))
print(old_fn[:500])

new_fn = '''def call_deepseek(cfg: dict, system: str, user_content: str) -> str:
    """Call DeepSeek with retries; on 503/timeout fall back to chat model."""
    base = cfg.get("base_url", "https://api.deepseek.com").rstrip("/")
    url = base if base.endswith("/chat/completions") else base + "/chat/completions"
    primary = str(cfg.get("model", "deepseek-chat"))
    fallback = str(cfg.get("fallback_model", "deepseek-chat")).strip() or "deepseek-chat"
    models = [primary]
    if fallback and fallback != primary:
        models.append(fallback)

    timeout = float(cfg.get("timeout_sec", 45))
    retries = max(1, int(cfg.get("api_retries", 3)))
    retry_sleep = float(cfg.get("api_retry_sleep_sec", 2))
    last_err: Exception | None = None

    for model in models:
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user_content},
            ],
            "temperature": float(cfg.get("temperature", 0.2)),
            "max_tokens": int(cfg.get("max_tokens", 80 if _is_reasoner(model) else 60)),
        }
        # reasoner 更慢，单独加长超时
        to = timeout * (1.8 if _is_reasoner(model) else 1.0)
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
                with urllib.request.urlopen(req, timeout=to) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                msg = data["choices"][0]["message"]
                text_out = _message_text(msg)
                if not text_out:
                    raise RuntimeError("empty model content")
                if model != primary:
                    print(f"[API] 已用备用模型 {model}")
                return text_out
            except urllib.error.HTTPError as e:
                body_err = e.read().decode("utf-8", errors="ignore")
                last_err = e
                busy = e.code in (429, 500, 502, 503, 504)
                print(f"[API] {model} HTTP {e.code} 第{attempt}/{retries}次: {body_err[:160]}")
                if not busy or attempt >= retries:
                    break
                time.sleep(retry_sleep * attempt)
            except Exception as e:
                last_err = e
                print(f"[API] {model} 第{attempt}/{retries}次失败 ({e}), {retry_sleep:.0f}s后重试...")
                if attempt >= retries:
                    break
                time.sleep(retry_sleep * attempt)
        if model != models[-1]:
            print(f"[API] 主模型失败，切换备用 {fallback}")

    raise RuntimeError(f"DeepSeek 调用失败: {last_err}")

'''

text2 = text[:idx] + new_fn + text[end:]
# ensure Exception | None works on 3.9 - use Optional if needed - user has py3
lib.write_text(text2, encoding="utf-8")
print("patched", lib)

# patch config next to lib
cfg = lib.parent / "data" / "deepseek_config.json"
ex = lib.parent / "data" / "deepseek_config.example.json"
for p in (cfg, ex):
    if not p.exists():
        continue
    data = json.loads(p.read_text(encoding="utf-8"))
    # prefer chat for reliability when distributing
    if "reasoner" in str(data.get("model", "")).lower():
        data["model"] = "deepseek-chat"
        print(p.name, "model -> deepseek-chat")
    data.setdefault("fallback_model", "deepseek-chat")
    data["timeout_sec"] = max(int(data.get("timeout_sec", 30)), 45)
    data["api_retries"] = int(data.get("api_retries", 3))
    data["api_retry_sleep_sec"] = float(data.get("api_retry_sleep_sec", 2))
    data["interval_sec"] = max(int(data.get("interval_sec", 60)), 45)
    data["dir_max_sec"] = max(int(data.get("dir_max_sec", 90)), 90)
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("updated", p)

# also patch F:\\EA\\tools bridge
import json
ea = Path(r"F:\EA\tools\ai_signal_bridge.py")
et = ea.read_text(encoding="utf-8")
if "api_retries" not in et:
    old = '''def call_deepseek(cfg: dict, user_content: str) -> str:
    url = cfg.get("base_url", "https://api.deepseek.com/chat/completions").rstrip("/")
    if not url.endswith("/chat/completions"):
        url = url + "/chat/completions"
    payload = {
        "model": cfg.get("model", "deepseek-chat"),
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ],
        "temperature": float(cfg.get("temperature", 0.2)),
        "max_tokens": int(cfg.get("max_tokens", 60)),
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {cfg['api_key']}",
        },
        method="POST",
    )
    timeout = float(cfg.get("timeout_sec", 30))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data["choices"][0]["message"]["content"].strip()
'''
    new = '''def call_deepseek(cfg: dict, user_content: str) -> str:
    url = cfg.get("base_url", "https://api.deepseek.com/chat/completions").rstrip("/")
    if not url.endswith("/chat/completions"):
        url = url + "/chat/completions"
    primary = str(cfg.get("model", "deepseek-chat"))
    fallback = str(cfg.get("fallback_model", "deepseek-chat")).strip() or "deepseek-chat"
    models = [primary] + ([fallback] if fallback != primary else [])
    timeout = float(cfg.get("timeout_sec", 45))
    retries = max(1, int(cfg.get("api_retries", 3)))
    retry_sleep = float(cfg.get("api_retry_sleep_sec", 2))
    last_err: Exception | None = None
    for model in models:
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
            ],
            "temperature": float(cfg.get("temperature", 0.2)),
            "max_tokens": int(cfg.get("max_tokens", 60)),
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
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                text = data["choices"][0]["message"]["content"].strip()
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
'''
    if old not in et:
        print("EA bridge call_deepseek pattern mismatch, skip")
    else:
        ea.write_text(et.replace(old, new), encoding="utf-8")
        print("patched", ea)

for p in (
    Path(r"F:\EA\tools\data\deepseek_config.json"),
    Path(r"F:\EA\tools\data\deepseek_config.example.json"),
):
    if not p.exists():
        continue
    data = json.loads(p.read_text(encoding="utf-8"))
    data["model"] = "deepseek-chat"
    data["fallback_model"] = "deepseek-chat"
    data["timeout_sec"] = 45
    data["api_retries"] = 3
    data["api_retry_sleep_sec"] = 2
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("updated", p)

# client tip file
tip = Path(r"F:\EA\tools\DeepSeek忙时说明.txt")
tip.write_text(
    """DeepSeek 报 timeout / HTTP 503 时怎么办（给客户）

原因：DeepSeek 云端忙或网络慢，不是 EA 坏了。

必做：
1) 每人用自己的 API Key（不要多人共用一个 Key）
2) 配置里用 deepseek-chat（不要用 deepseek-reasoner，更慢更容易超时）
3) 保持桥接窗口开着；失败会自动重试，偶发 503 等几分钟即可

配置文件 data/deepseek_config.json 建议：
  "model": "deepseek-chat"
  "fallback_model": "deepseek-chat"
  "timeout_sec": 45
  "api_retries": 3
  "api_retry_sleep_sec": 2

长期仍不稳：换其它兼容 OpenAI 接口的中转，或改 base_url。
""",
    encoding="utf-8",
)
print("wrote", tip)

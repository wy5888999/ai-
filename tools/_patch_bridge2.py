# -*- coding: utf-8 -*-
import json
from pathlib import Path

cands = [
    p
    for p in Path(r"C:\Users\Administrator\Desktop\823").rglob("ai_bridge_lib.py")
    if "__pycache__" not in p.parts and "data" not in p.parts
]
lib = cands[0]
text = lib.read_text(encoding="utf-8")
# sanity
assert "fallback_model" in text and "api_retries" in text
print("lib ok", lib)
# syntax check
compile(text, str(lib), "exec")
print("syntax ok")

for p in list((lib.parent / "data").glob("deepseek_config*.json")) + [
    Path(r"F:\EA\tools\data\deepseek_config.json"),
    Path(r"F:\EA\tools\data\deepseek_config.example.json"),
]:
    if not p.exists():
        continue
    data = json.loads(p.read_text(encoding="utf-8"))
    if "reasoner" in str(data.get("model", "")).lower():
        data["model"] = "deepseek-chat"
    data["model"] = data.get("model") or "deepseek-chat"
    data["fallback_model"] = data.get("fallback_model") or "deepseek-chat"
    data["timeout_sec"] = max(int(data.get("timeout_sec", 30)), 45)
    data["api_retries"] = int(data.get("api_retries", 3))
    data["api_retry_sleep_sec"] = float(data.get("api_retry_sleep_sec", 2))
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("cfg", p, "model=", data["model"])

# patch EA tools bridge if needed
ea = Path(r"F:\EA\tools\ai_signal_bridge.py")
et = ea.read_text(encoding="utf-8")
if "api_retries" not in et:
    # insert retry wrapper by replacing simple urlopen block
    needle = '    timeout = float(cfg.get("timeout_sec", 30))\n    with urllib.request.urlopen(req, timeout=timeout) as resp:\n        data = json.loads(resp.read().decode("utf-8"))\n    return data["choices"][0]["message"]["content"].strip()\n'
    if needle in et:
        # bigger replace already attempted; do full function via marker
        pass
    print("EA bridge needs manual check, api_retries missing")
else:
    print("EA bridge already has retries")
    compile(et, str(ea), "exec")

tip = Path(r"F:\EA\tools\DeepSeek忙时说明.txt")
tip.write_text(
    "DeepSeek 报 timeout / HTTP 503 时怎么办（给客户）\n\n"
    "原因：DeepSeek 云端忙或网络慢，不是 EA 坏了。\n\n"
    "必做：\n"
    "1) 每人用自己的 API Key（不要多人共用一个 Key）\n"
    "2) 配置里用 deepseek-chat（不要用 deepseek-reasoner）\n"
    "3) 保持桥接窗口开着；失败会自动重试\n\n"
    "data/deepseek_config.json 建议：\n"
    '  "model": "deepseek-chat"\n'
    '  "fallback_model": "deepseek-chat"\n'
    '  "timeout_sec": 45\n'
    '  "api_retries": 3\n',
    encoding="utf-8",
)
print("tip", tip)

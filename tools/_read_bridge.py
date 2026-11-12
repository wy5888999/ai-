# -*- coding: utf-8 -*-
from pathlib import Path
cands = list(Path(r"C:\Users\Administrator\Desktop\823").rglob("ai_signal_bridge_dir.py"))
cands += list(Path(r"C:\Users\Administrator\Desktop\823").rglob("ai_bridge_lib.py"))
for p in cands:
    if "__pycache__" in str(p) or "data" in p.parts:
        continue
    print("===", p)
    print(p.read_text(encoding="utf-8", errors="replace")[:4000])
    print()

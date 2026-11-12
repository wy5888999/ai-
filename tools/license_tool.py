#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""命令行授权签发（可选）。图形界面请用 auth_gui.py。"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import license_core as core


def main() -> None:
    parser = argparse.ArgumentParser(description="命令行签发 .lic")
    parser.add_argument("--account", type=int, required=True)
    parser.add_argument("--expiry", type=str, required=True, help="YYYYMMDD")
    parser.add_argument("--secret", type=str, help="不填则读 config.json")
    args = parser.parse_args()

    cfg = core.load_config()
    secret = args.secret or cfg["license_secret"]
    user = {
        "username": str(args.account),
        "mt5_account": args.account,
        "expiry": args.expiry,
    }
    # 临时覆盖 secret
    cfg = dict(cfg)
    cfg["license_secret"] = secret
    key, path = core.issue_license_files(user, cfg)
    print(key)
    print(path)


if __name__ == "__main__":
    main()

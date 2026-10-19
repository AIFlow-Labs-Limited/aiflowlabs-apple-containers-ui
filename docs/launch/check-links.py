#!/usr/bin/env python3
"""Fail if README.md (or the files given) references a relative path that does not exist.

Checks Markdown links/images `](path)` and HTML `src=`/`srcset=`/`href=` attributes; skips URLs and #anchors.
Run from the repo root: python3 docs/launch/check-links.py [README.md ...]
"""
import os
import re
import sys

files = sys.argv[1:] or ["README.md"]
pattern = re.compile(r"\]\(([^)\s]+)\)|(?:src|srcset|href)=\"([^\"]+)\"")
missing = []
for md in files:
    base = os.path.dirname(md)
    text = open(md, encoding="utf-8").read()
    for m in pattern.finditer(text):
        target = (m.group(1) or m.group(2)).split("#")[0].split(" ")[0]
        if not target or re.match(r"^[a-z]+:", target):
            continue
        if not os.path.exists(os.path.join(base, target)):
            missing.append(f"{md}: {target}")
print("\n".join(missing) or f"ok: every relative link in {', '.join(files)} exists")
sys.exit(1 if missing else 0)

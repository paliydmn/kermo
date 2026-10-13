#!/usr/bin/env python3
"""Checks the relative links and #anchors in README.md, CONTRIBUTING.md and docs/*.md. Run: python3 tools/check-docs.py"""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
files = [root / "README.md", root / "CONTRIBUTING.md", *sorted((root / "docs").glob("*.md"))]

def text_without_code(path):
    return re.sub(r"```.*?```", "", path.read_text(), flags=re.S)

def slugs(path):
    seen, out = {}, set()
    for line in text_without_code(path).splitlines():
        m = re.match(r"#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m: continue
        s = re.sub(r"[^\w\- ]", "", re.sub(r"[`*]", "", m.group(1)).lower()).replace(" ", "-")
        n = seen.get(s, 0); seen[s] = n + 1
        out.add(s if n == 0 else f"{s}-{n}")
    return out

bad = 0
for f in files:
    for target in re.findall(r"\]\(([^)\s]+)\)", text_without_code(f)):
        if re.match(r"(https?|mailto):", target): continue
        path, _, anchor = target.partition("#")
        dest = (f.parent / path).resolve() if path else f
        if not dest.exists():
            print(f"{f.relative_to(root)}: missing file {target}"); bad += 1
        elif anchor and dest.suffix == ".md" and anchor not in slugs(dest):
            print(f"{f.relative_to(root)}: no heading #{anchor} in {dest.relative_to(root)}"); bad += 1
print("docs links: ok" if not bad else f"docs links: {bad} broken")
sys.exit(bool(bad))

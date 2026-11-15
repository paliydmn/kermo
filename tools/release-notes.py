#!/usr/bin/env python3
"""A release's notes and its latest.json, from CHANGELOG.md.

Usage: python3 tools/release-notes.py X.Y [lead.md]
Writes dist/Kermo-X.Y-notes.md (the lead, then the [X.Y] section: the GitHub release's notes) and dist/latest.json
(the API's tag_name, body and assets): attach latest.json to the release. Kermo's daily check downloads it, and its
download count is how many checks there were.
"""
import json, os, re, sys

version = sys.argv[1]
lead = open(sys.argv[2], encoding="utf-8").read().strip() if len(sys.argv) > 2 else ""
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
built = re.search(r"CFBundleShortVersionString</key><string>([^<]+)<", open(os.path.join(root, "build.sh")).read())
if not built or built.group(1) != version:
    sys.exit(f"build.sh says {built and built.group(1)}, not {version}")
changelog = open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8").read()
m = re.search(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\n(.*?)(?=^## \[)", changelog, re.S | re.M)
if not m:
    sys.exit(f"no [{version}] section in CHANGELOG.md")
body = "\n\n".join(p for p in (lead, m.group(1).strip()) if p) + "\n"
tag, base = f"v{version}", "https://github.com/paliydmn/kermo/releases/download"
names = [f"Kermo-{version}-universal.{ext}" for ext in ("dmg", "dmg.sha256", "pkg", "pkg.sha256", "zip")]
dist = os.path.join(root, "dist")
missing = [n for n in names if not os.path.exists(os.path.join(dist, n))]
if missing:   # latest.json lists them all: Install and Relaunch takes its zip, run ./package.sh first
    sys.exit("not in dist/: " + ", ".join(missing))
with open(os.path.join(dist, f"Kermo-{version}-notes.md"), "w", encoding="utf-8") as f:
    f.write(body)
latest = {"tag_name": tag, "body": body, "assets": [{"name": n, "browser_download_url": f"{base}/{tag}/{n}"} for n in names]}
with open(os.path.join(dist, "latest.json"), "w", encoding="utf-8") as f:
    json.dump(latest, f, ensure_ascii=False, indent=1)
print(f"dist/Kermo-{version}-notes.md, dist/latest.json ({tag})")

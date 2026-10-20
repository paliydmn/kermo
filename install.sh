#!/bin/sh
# Installs or updates Kermo from its latest GitHub release. Run it in Terminal (not in Kermo's own terminal: it quits Kermo):
#   curl -fsSL https://raw.githubusercontent.com/paliydmn/kermo/master/install.sh | sh
# curl adds no quarantine, so macOS doesn't ask for Open Anyway: running this is the trust Gatekeeper would ask for.
set -eu
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "Kermo needs macOS 14 or later." >&2; exit 1; }

repo=https://github.com/paliydmn/kermo
tag=$(curl -fsSL https://api.github.com/repos/paliydmn/kermo/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
[ -n "$tag" ] || { echo "Couldn't find the latest release on GitHub." >&2; exit 1; }
dmg=Kermo-${tag#v}-universal.dmg
app=/Applications/Kermo.app
tmp=$(mktemp -d)
trap 'hdiutil detach -quiet "$tmp/m" 2>/dev/null; rm -rf "$tmp"' EXIT

echo "Downloading Kermo ${tag#v}…"
curl -fL# -o "$tmp/$dmg" "$repo/releases/download/$tag/$dmg"
curl -fsSL -o "$tmp/sum" "$repo/releases/download/$tag/$dmg.sha256"
[ "$(shasum -a 256 "$tmp/$dmg" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$tmp/sum")" ] || { echo "The download is damaged: checksum doesn't match." >&2; exit 1; }
hdiutil attach -quiet -nobrowse -mountpoint "$tmp/m" "$tmp/$dmg"

if pgrep -xq Kermo; then
  echo "Quitting Kermo…"
  osascript -e 'quit app "Kermo"' >/dev/null 2>&1 || true
  i=0; while pgrep -xq Kermo && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  pgrep -xq Kermo && { echo "Kermo is still open. Quit it, then run this again." >&2; exit 1; }
fi

# A .pkg install leaves Kermo owned by root, and a standard user can't write to Applications: then sudo asks.
s=; { [ -e "$app" ] && [ ! -w "$app/Contents" ]; } || [ ! -w /Applications ] && s=sudo
$s rm -rf "$app"
$s ditto "$tmp/m/Kermo.app" "$app"
echo "Kermo ${tag#v} is in Applications."
open "$app"

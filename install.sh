#!/bin/sh
# Installs or updates Kermo from its latest GitHub release. Run it in Terminal (not in Kermo's own terminal: it quits Kermo):
#   curl -fsSL https://raw.githubusercontent.com/paliydmn/kermo/master/install.sh | sh
# curl adds no quarantine, so macOS doesn't ask for Open Anyway: running this is the trust Gatekeeper would ask for.
# All of it is one function called on the last line: a download cut off midway runs nothing.
set -eu

# What Install and Relaunch checks too (Updates.isSigned): Kermo's identifier, signed with the Kermo Release Signing
# certificate (its SHA-1). The checksum next to the file only catches a damaged download: whoever could swap the
# file could swap the checksum too.
requirement='identifier "com.dmn.dfilemanager" and certificate leaf = H"d3bd6ce342db8977ebddfcd8aad30158f53a1f68"'

main() {
  [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "Kermo needs macOS 14 or later." >&2; exit 1; }

  repo=https://github.com/paliydmn/kermo
  tag=$(curl -fsSL https://api.github.com/repos/paliydmn/kermo/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
  [ -n "$tag" ] || { echo "Couldn't find the latest release on GitHub." >&2; exit 1; }
  pkg=Kermo-${tag#v}-universal.pkg
  app=/Applications/Kermo.app
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading Kermo ${tag#v}…"
  curl -fL# -o "$tmp/$pkg" "$repo/releases/download/$tag/$pkg"
  curl -fsSL -o "$tmp/sum" "$repo/releases/download/$tag/$pkg.sha256"
  [ "$(shasum -a 256 "$tmp/$pkg" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$tmp/sum")" ] || { echo "The download is damaged: checksum doesn't match." >&2; exit 1; }
  # The app is taken out of the .pkg, not the DMG: mounting a disk image asks for a password on recent macOS.
  pkgutil --expand-full "$tmp/$pkg" "$tmp/x"
  new=$tmp/x/Payload/Kermo.app
  codesign --verify --deep --strict -R "=$requirement" "$new" 2>/dev/null ||
    { echo "The download isn't signed by Kermo's release certificate: nothing was installed." >&2; exit 1; }

  if pgrep -xq Kermo; then
    echo "Quitting Kermo…"
    osascript -e 'quit app "Kermo"' >/dev/null 2>&1 || true
    i=0; while pgrep -xq Kermo && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    pgrep -xq Kermo && { echo "Kermo is still open. Quit it, then run this again." >&2; exit 1; }
  fi

  # A .pkg install leaves Kermo owned by root, and a standard user can't write to Applications: then sudo asks.
  # The same for what a stopped run left beside it.
  s=; [ -w /Applications ] || s=sudo
  for a in "$app" "$app.old" "$app.new"; do [ ! -e "$a" ] || [ -w "$a/Contents" ] || s=sudo; done
  # A run stopped between the two moves below left Kermo only as .old: it goes back first.
  [ -e "$app" ] || [ ! -e "$app.old" ] || $s mv "$app.old" "$app"
  $s rm -rf "$app.new" "$app.old"
  # Copied beside the old one, then swapped: a stop midway leaves a whole Kermo, not none.
  $s ditto "$new" "$app.new"
  [ ! -e "$app" ] || $s mv "$app" "$app.old"
  $s mv "$app.new" "$app" || { [ ! -e "$app.old" ] || $s mv "$app.old" "$app"; exit 1; }
  $s rm -rf "$app.old"
  echo "Kermo ${tag#v} is in Applications."
  open "$app"
}

main "$@"

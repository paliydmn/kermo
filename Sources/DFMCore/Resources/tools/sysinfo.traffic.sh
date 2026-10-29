#!/bin/sh
# Traffic on each interface over 5 seconds, from /proc/net/dev (no tools to install).
a=$(cat /proc/net/dev); sleep 5; b=$(cat /proc/net/dev)
printf '%s\n--\n%s\n' "$a" "$b" | awk '
  /^--$/ { second = 1; next }
  { sub(/^ +/, ""); sub(/:/, " ") }
  $2 !~ /^[0-9]+$/ { next }
  !second { rx[$1] = $2; tx[$1] = $10; next }
  ($1 in rx) { printf "%-14s down %9.1f KB/s   up %9.1f KB/s\n", $1, ($2 - rx[$1]) / 5120, ($10 - tx[$1]) / 5120 }'

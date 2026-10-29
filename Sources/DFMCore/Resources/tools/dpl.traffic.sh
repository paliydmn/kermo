#!/bin/sh
# dpl preset stream: requests, 5xx and p95 per domain from the http-server's access.log (JSONL: time, host, ip, method,
# uri, status, duration, size, …), one JSON line every $EVERY seconds. Reads only the bytes added since the last pass;
# a smaller file means it was rotated, so it starts over. Read-only; ends with the SSH channel.
# p95 comes from geometric buckets (×1.25 from 1 ms): within 25 %, and O(n) however busy the site is.
# The first http-server unit's access.log under BASE, unless LOG names one.
[ -n "$LOG" ] || for LOG in "${BASE:-/opt/dpl}"/state/*/log/access.log; do break; done
EVERY=${EVERY:-10}
off=$(wc -c < "$LOG" 2>/dev/null || echo 0)
while :; do
  sleep "$EVERY"
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$size" -lt "$off" ] && off=0
  tail -c +$((off + 1)) "$LOG" 2>/dev/null | head -c $((size - off)) | LC_ALL=C awk -v every="$EVERY" '
    function field(s, k,   v) {
      if (!match(s, "\"" k "\": *\"?[^\",}]*")) return ""
      v = substr(s, RSTART, RLENGTH); sub(/^"[^"]*": *"?/, "", v); return v
    }
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    {
      h = field($0, "host"); st = field($0, "status") + 0; ms = field($0, "duration") * 1000
      if (h == "" || st == 0) next
      n[h]++; if (st >= 500) e[h]++
      b = ms < 1 ? 0 : int(log(ms) / log(1.25)) + 1; c[h, b]++; if (b > top[h]) top[h] = b
    }
    END {
      out = ""
      for (h in n) {
        need = n[h] * 0.95; sum = 0
        for (b = 0; b <= top[h]; b++) { sum += c[h, b]; if (sum >= need) break }
        p95 = b == 0 ? 1 : int(1.25 ^ b + 0.5)
        out = out (out ? "," : "") sprintf("{\"host\":\"%s\",\"req\":%d,\"rpm\":%d,\"e5\":%d,\"e5_pct\":%.1f,\"p95_ms\":%d}", esc(h), n[h], n[h] * 60 / every, e[h], 100 * e[h] / n[h], p95)
      }
      print "{\"hosts\":[" out "]}"; fflush()
    }'
  off=$size
done

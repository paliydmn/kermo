#!/bin/sh
# System preset: one JSON line every $EVERY seconds (default 5) for as long as the SSH channel stays open.
# Read-only: /proc, df, ps, systemctl, docker/podman ps. Nothing is installed or written on the server; when the channel
# closes, the next write fails and awk ends. CPU %, rates and per-process CPU come from the difference between two reads,
# so the first line carries no rates. Heavier reads are spaced out: processes every 3rd line, disks every 6th,
# units and containers every 12th. A process's "start" (clock ticks after boot, /proc/<pid>/stat) lets Stop and Kill
# check that its pid is still the same process.
LC_ALL=C exec awk -v every="${EVERY:-5}" '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
function num(v) { return sprintf("%.1f", v) + 0 }
function num2(v) { return sprintf("%.2f", v) + 0 }
function first(f,   l) { l = ""; getline l < f; close(f); return l }

function cpu(   l, f, n, i, tot, idle, iow, stl) {
  cores = 0
  while ((getline l < "/proc/stat") > 0) {
    n = split(l, f, " ")
    if (f[1] == "cpu") { tot = 0; for (i = 2; i <= 9 && i <= n; i++) tot += f[i]; idle = f[5] + f[6]; iow = f[6]; stl = n >= 9 ? f[9] : 0 }
    else if (f[1] ~ /^cpu[0-9]/) cores++
  }
  close("/proc/stat")
  if (have) { d = tot - ptot; if (d > 0) out = out sprintf(",\"cpu\":{\"pct\":%s,\"iowait\":%s,\"steal\":%s}", num(100 * (d - (idle - pidle)) / d), num(100 * (iow - piow) / d), num(100 * (stl - pstl) / d)) }
  ptot = tot; pidle = idle; piow = iow; pstl = stl
}

function mem(   l, f, m, total, avail, used, swt, swu, si, so, swapping, pct) {
  while ((getline l < "/proc/meminfo") > 0) { split(l, f, /[: ]+/); m[f[1]] = f[2] * 1024 }
  close("/proc/meminfo")
  total = m["MemTotal"]; avail = ("MemAvailable" in m) ? m["MemAvailable"] : m["MemFree"] + m["Buffers"] + m["Cached"]
  used = total - avail; swt = m["SwapTotal"]; swu = swt - m["SwapFree"]
  while ((getline l < "/proc/vmstat") > 0) { split(l, f, " "); if (f[1] == "pswpin") si = f[2]; else if (f[1] == "pswpout") so = f[2]; else if (f[1] == "oom_kill") oom = f[2] }
  close("/proc/vmstat")
  swapping = have && (si + so - pswap) > 0; pswap = si + so
  pct = total ? 100 * used / total : 0
  out = out sprintf(",\"mem\":{\"pct\":%s,\"used\":%.0f,\"total\":%.0f,\"swapping_pct\":%s},\"swap\":{\"pct\":%s,\"used\":%.0f,\"total\":%.0f}", \
    num(pct), used, total, swapping ? num(pct) : 0, swt ? num(100 * swu / swt) : 0, swu, swt)
  if (oom != "") out = out ",\"oom_kill\":" oom
}

function load(   f) {
  split(first("/proc/loadavg"), f, " ")
  out = out sprintf(",\"load\":{\"1\":%s,\"5\":%s,\"15\":%s,\"per_core\":%s},\"cores\":%d", f[1], f[2], f[3], num2(f[1] / (cores ? cores : 1)), cores)
}

function net(   l, f, a, name, rx, tx) {
  while ((getline l < "/proc/net/dev") > 0) {
    if (index(l, ":") == 0) continue
    name = substr(l, 1, index(l, ":") - 1); gsub(/ /, "", name)
    if (name ~ /^(lo|veth|docker|br-|virbr|cni|flannel)/) continue
    split(substr(l, index(l, ":") + 1), a, " "); rx += a[1]; tx += a[9]
  }
  close("/proc/net/dev")
  if (have && dt > 0) out = out sprintf(",\"net\":{\"rx\":%.0f,\"tx\":%.0f}", (rx - prx) / dt, (tx - ptx) / dt)
  prx = rx; ptx = tx
}

function io(   l, f, r, w) {
  while ((getline l < "/proc/diskstats") > 0) {
    split(l, f, " ")
    if (f[3] ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/) { r += f[6] * 512; w += f[10] * 512 }
  }
  close("/proc/diskstats")
  if (have && dt > 0) out = out sprintf(",\"io\":{\"read\":%.0f,\"write\":%.0f}", (r - pr) / dt, (w - pw) / dt)
  pr = r; pw = w
}

function procs(   cmd, l, f, n, i, c, pid, t, pct, name, cur, best, rows, k, j, bi, bv, st, s) {
  cmd = "ps -eo pid=,user=,times=,pmem=,comm= 2>/dev/null"
  n = 0
  while ((cmd | getline l) > 0) {
    c = split(l, f, " "); pid = f[1]; t = f[3]
    name = f[5]; for (i = 6; i <= c; i++) name = name " " f[i]
    cur[pid] = t
    if (pid in ptimes && pdt > 0) { pct = 100 * (t - ptimes[pid]) / pdt; n++; P[n] = pct; U[n] = f[2]; M[n] = f[4]; C[n] = name; I[n] = pid }
  }
  close(cmd)
  delete ptimes; for (pid in cur) ptimes[pid] = cur[pid]
  if (!n) return
  rows = ""
  for (k = 1; k <= 8 && k <= n; k++) {
    bi = 0; bv = -1
    for (j = 1; j <= n; j++) if (!(j in used) && P[j] > bv) { bv = P[j]; bi = j }
    used[bi] = 1
    st = first("/proc/" I[bi] "/stat"); sub(/.*\) /, "", st); split(st, s, " ")   # after the name, which may hold ") "
    rows = rows (k > 1 ? "," : "") sprintf("{\"pid\":%d,\"start\":\"%s\",\"user\":\"%s\",\"cpu\":%s,\"mem\":%s,\"command\":\"%s\"}", I[bi], s[20], esc(U[bi]), num(P[bi]), M[bi] + 0, esc(C[bi]))
  }
  out = out ",\"procs\":[" rows "]"
  delete P; delete U; delete M; delete C; delete I; delete used
}

function disks(   cmd, l, f, rows, ip, seen) {
  cmd = "df -Pi 2>/dev/null"
  while ((cmd | getline l) > 0) { split(l, f, " "); sub(/%/, "", f[5]); ip[f[6]] = f[5] }
  close(cmd)
  cmd = "df -P 2>/dev/null"; rows = ""
  while ((cmd | getline l) > 0) {
    split(l, f, " ")
    if (f[1] ~ /^(Filesystem|tmpfs|devtmpfs|overlay|squashfs|udev|none|shm|efivarfs)$/ || f[6] ~ /^\/(run|dev|sys|proc|snap)(\/|$)/ || (f[6] in seen)) continue
    seen[f[6]] = 1; sub(/%/, "", f[5])
    rows = rows (rows ? "," : "") sprintf("{\"mount\":\"%s\",\"pct\":%d,\"inodes_pct\":%d,\"used\":%.0f,\"size\":%.0f}", esc(f[6]), f[5], (ip[f[6]] ~ /^[0-9]+$/) ? ip[f[6]] : 0, f[3] * 1024, f[2] * 1024)
  }
  close(cmd)
  out = out ",\"disks\":[" rows "]"
}

function units(   cmd, l, f, rows) {
  cmd = "systemctl --failed --no-legend --plain 2>/dev/null"; rows = ""
  while ((cmd | getline l) > 0) { split(l, f, " "); if (f[1] != "") rows = rows (rows ? "," : "") "{\"unit\":\"" esc(f[1]) "\"}" }
  close(cmd)
  out = out ",\"failed_units\":[" rows "]"
  cmd = "{ docker ps -a --format \"{{.Names}}|{{.State}}|{{.Status}}\" || podman ps -a --format \"{{.Names}}|{{.State}}|{{.Status}}\"; } 2>/dev/null"; rows = ""
  while ((cmd | getline l) > 0) { split(l, f, "|"); rows = rows (rows ? "," : "") sprintf("{\"name\":\"%s\",\"state\":\"%s\",\"status\":\"%s\"}", esc(f[1]), esc(f[2]), esc(f[3])) }
  close(cmd)
  out = out ",\"containers\":[" rows "]"
  out = out ",\"reboot_required\":" ((getline l < "/var/run/reboot-required") > 0 ? "true" : "false"); close("/var/run/reboot-required")
}

BEGIN {
  boot = first("/proc/sys/kernel/random/boot_id")
  for (tick = 0; ; tick++) {
    split(first("/proc/uptime"), u, " "); up = u[1]; dt = up - pup
    out = sprintf("{\"uptime\":%.0f,\"boot_id\":\"%s\"", up, boot)
    cpu(); mem(); load(); net(); io()
    if (tick % 3 == 0) { pdt = up - pup3; procs(); pup3 = up }
    if (tick % 6 == 0) disks()
    if (tick % 12 == 0) units()
    print out "}"; fflush()
    have = 1; pup = up
    system("sleep " every)
  }
}'

#!/bin/sh
# System preset: one JSON line every $EVERY seconds (default 5) for as long as the SSH channel stays open.
# Read-only: /proc, df, ps, systemctl, docker/podman ps. Nothing is installed or written on the server; when the channel
# closes, the next write fails and awk ends. CPU %, rates and per-process CPU come from the difference between two reads,
# so the first line carries no rates. Heavier reads are spaced out: processes every 3rd line, disks every 6th,
# units and containers every 12th. A process's "start" (clock ticks after boot, /proc/<pid>/stat) and "boot" (this
# boot's id) let Stop and Kill check that its pid is still the same process; its "kind" keeps them off pid 1, kernel
# threads and this connection. The top $TOP by CPU and by memory (default 8 each); TOP=0: every process.
# ONCE=1 (the list, All Processes…): one line with the processes alone, from two reads a second apart, and done.
LC_ALL=C exec awk -v every="${EVERY:-5}" -v top="${TOP:-8}" -v once="${ONCE:-}" '
# A JSON string: \ and " escaped by split and join — a backslash in a gsub replacement means different things to
# different awks (Debian 12 mawk keeps it single) — and control characters as spaces.
function rep(s, c, by,   n, p, i, r) { n = split(s, p, c); r = p[1]; for (i = 2; i <= n; i++) r = r by p[i]; return r }
function esc(s) { s = rep(s, "\\", "\\\\"); s = rep(s, "\"", "\\\""); gsub(ctl, " ", s); return s }
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
  pct = total ? 100 * used / total : 0; memtotal = total
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

# /proc/<pid>/stat as one line — a name may hold a line break — and its fields after the name, which may hold ") ":
# s[1] state, s[2] parent, s[3] process group, s[5] terminal, s[7] flags, s[12] + s[13] CPU ticks, s[20] start,
# s[22] resident pages. Its name goes to `name`. The same in system.deleted.sh, with mine, under and kind: keep them alike.
function stat(pid, s,   f, l, st, i) {
  f = "/proc/" pid "/stat"; st = ""
  while ((getline l < f) > 0) st = st (st == "" ? "" : " ") l
  close(f)
  i = index(st, "("); if (!i || !match(st, /.*\) /)) return 0
  name = substr(st, i + 1, RLENGTH - i - 2)
  return split(substr(st, RLENGTH + 1), s, " ") >= 22
}

# "self": this awk, the processes above it — the payload shell, the sshd of this connection, the main sshd — and the
# rest of its process group: the payload Kermo runs it in (its other sources, the watcher whose end ends them all).
# Also what runs with no terminal under the sshd of this connection (the nearest sshd above): the other channels of Kermo
# on it — watching, the SFTP of a panel, the read of a list. A program in the terminal tab of Kermo has its terminal: "user".
function mine(   s, p) {
  delete SELF; group = ""; conn = ""
  for (p = me; p > 1 && !(p in SELF) && stat(p, s); p = s[2]) {
    SELF[p] = 1; if (group == "") group = s[3]
    if (conn == "" && name ~ /^(sshd|dropbear)/) conn = p
  }
}

# Whether `pid` runs under the sshd of this connection: by the parents the caller has (PP), else as /proc says.
function under(pid,   n, s) {
  for (n = 0; conn != "" && pid > 1 && n < 64; n++) {
    if (pid == conn) return 1
    if (pid in PP) pid = PP[pid]; else if (stat(pid, s)) pid = s[2]; else return 0
  }
  return 0
}

# What Stop and Kill may not touch: pid 1 ("init"), a kernel thread (PF_KTHREAD in its flags: "kernel"), "self"; the
# rest is "user".
function kind(pid, flags, pgrp, tty) {
  return pid == 1 ? "init" : int(flags / 2097152) % 2 ? "kernel" : (pid in SELF) || pgrp == group || (!tty && under(pid)) ? "self" : "user"
}

# The systemd unit a process runs in, from its cgroup (v2 "0::", else name=systemd of v1): a service ("nginx.service"),
# the user manager of the services of a user ("user@1000.service"), a scope ("session-4.scope"), or "container".
function unit(pid,   f, l, path, v1, n, c, i) {
  f = "/proc/" pid "/cgroup"; path = ""
  while ((getline l < f) > 0) {
    if (substr(l, 1, 3) == "0::") path = substr(l, 4)
    else if (index(l, ":name=systemd:")) v1 = substr(l, index(l, ":name=systemd:") + 14)
  }
  close(f)
  if (path == "" || path == "/") path = v1
  utype = ""
  if (path ~ /(docker|libpod|crio|cri-containerd|lxc)[-\/]|kubepods|machine\.slice/) { utype = "container"; return "container" }
  n = split(path, c, "/")
  for (i = 1; i <= n; i++) if (c[i] ~ /^user@[0-9]+\.service$/) { utype = "service"; return c[i] }
  for (i = n; i >= 1; i--) if (c[i] ~ /\.(service|scope)$/) { utype = c[i] ~ /service$/ ? "service" : "scope"; return c[i] }
  return ""
}

# The processes: one ps for users and command lines, then /proc/<pid>/stat — CPU ticks of the kernel (ps
# gives whole seconds), state, parent, memory, start. The CPU of a process is its ticks since the last read of the same pid
# and start (a pid given to another process starts again; one started since has all its ticks since), in % of one core as
# top shows it. Rows: up to `top` that used the most CPU and `top` that hold the most memory, once each (none: all of
# them); the full command line only for those, cut to 200.
# ponytail: 16 rows with their command lines make a line of about 4 KB, past PIPE_BUF: with another tool watched in the
# same channel and the channel backed up, two lines can interleave and both samples are lost (ToolPayload.watch).
function procs(   cmd, l, a, s, n, i, j, k, m, pid, id, t, cur, pick, bv, bi, row, u, kd, base) {
  cmd = "{ ps -eo pid=,user:32=,args= || ps -eo pid=,user=,args=; } 2>/dev/null"; n = 0   # procps cuts a name to 8 ("systemd+"); busybox has no :32
  while ((cmd | getline l) > 0) {
    if (!match(l, /^ *[0-9]+ +[^ ]+ */)) continue
    split(substr(l, 1, RLENGTH), a, " "); pid = a[1]; a[3] = substr(l, RLENGTH + 1)   # before stat: its match moves RLENGTH
    if (!stat(pid, s)) continue
    PP[pid] = s[2]
    id = pid SUBSEP s[20]; t = s[12] + s[13]; cur[id] = t
    if (!pread || pdt <= 0) continue   # the first read: CPU takes two
    if (id in pticks) base = pticks[id]; else if (s[20] >= (pup3 - 1) * hz) base = 0; else continue   # started since, or missed
    n++; I[n] = pid; U[n] = a[2]; A[n] = a[3]; C[n] = name; S[n] = s[1]; T[n] = s[20]; F[n] = s[7]; G[n] = s[3]; Y[n] = s[5]
    P[n] = 100 * (t - base) / (hz * pdt); R[n] = s[22] * page
  }
  close(cmd)
  delete pticks; for (id in cur) pticks[id] = cur[id]
  pread = 1
  mine()
  m = 0
  if (!top) for (j = 1; j <= n; j++) O[++m] = j   # all of them, as ps has them
  for (k = 1; top && k <= 2 * top; k++) {   # the first `top` by CPU, then `top` by memory; none that used or holds nothing
    bi = 0; bv = 0
    for (j = 1; j <= n; j++) if (!(j in pick) && (k <= top ? P[j] : R[j]) > bv) { bv = k <= top ? P[j] : R[j]; bi = j }
    if (bi) { pick[bi] = 1; O[++m] = bi }
  }
  row = ""
  for (k = 1; k <= m; k++) {
    j = O[k]; pid = I[j]; kd = kind(pid, F[j], G[j], Y[j])
    row = row (k > 1 ? "," : "") sprintf("{\"pid\":%d,\"start\":\"%s\",\"boot\":\"%s\",\"user\":\"%s\",\"cpu\":%s,\"mem\":%s,\"rss\":%.0f,\"state\":\"%s\",\"kind\":\"%s\",\"command\":\"%s\"", \
      pid, T[j], boot8, esc(U[j]), num(P[j]), memtotal ? num(100 * R[j] / memtotal) : 0, R[j], S[j], kd, esc(C[j]))
    u = unit(pid); if (u != "") row = row ",\"unit\":\"" esc(u) "\",\"unit_type\":\"" utype "\""
    if (kd != "kernel" && A[j] != "") row = row ",\"args\":\"" esc(substr(A[j], 1, 200)) "\""
    row = row "}"
  }
  out = out ",\"procs\":[" row "]"
  delete I; delete U; delete A; delete C; delete S; delete T; delete F; delete G; delete Y; delete P; delete R; delete O; delete PP
}

# Disks as df -P has them, the virtual ones left out. Inodes only where the file system counts them (btrfs says "-").
function disks(   cmd, l, f, rows, ip, seen) {
  cmd = "df -Pi 2>/dev/null"
  while ((cmd | getline l) > 0) { split(l, f, " "); sub(/%/, "", f[5]); ip[f[6]] = f[5] }
  close(cmd)
  cmd = "df -P 2>/dev/null"; rows = ""
  while ((cmd | getline l) > 0) {
    split(l, f, " ")
    if (f[1] ~ /^(Filesystem|tmpfs|devtmpfs|overlay|squashfs|udev|none|shm|efivarfs)$/ || f[6] ~ /^\/(run|dev|sys|proc|snap)(\/|$)/ || (f[6] in seen)) continue
    seen[f[6]] = 1; sub(/%/, "", f[5])
    rows = rows (rows ? "," : "") sprintf("{\"mount\":\"%s\",\"pct\":%d,%s\"used\":%.0f,\"free\":%.0f,\"size\":%.0f}", esc(f[6]), f[5], \
      ip[f[6]] ~ /^[0-9]+$/ ? "\"inodes_pct\":" ip[f[6]] "," : "", f[3] * 1024, f[4] * 1024, f[2] * 1024)
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
  ctl = sprintf("[%c-%c%c]", 1, 31, 127)   # control characters: a JSON string never holds them as they are
  hz = 100; page = 4096   # the USER_HZ of Linux and the usual page, unless getconf says
  "getconf CLK_TCK 2>/dev/null" | getline hz; close("getconf CLK_TCK 2>/dev/null"); hz += 0; if (hz <= 0) hz = 100
  "getconf PAGESIZE 2>/dev/null" | getline page; close("getconf PAGESIZE 2>/dev/null"); page += 0; if (page <= 0) page = 4096
  split(first("/proc/self/stat"), u, " "); me = u[1]   # opened by awk itself: its own pid, wherever the payload put it
  boot = first("/proc/sys/kernel/random/boot_id"); boot8 = substr(boot, 1, 8)   # what Stop and Kill check: cut -c1-8
  if (once) {   # the list: the processes alone, from two reads a second apart
    mem(); split(first("/proc/uptime"), u, " "); pup3 = u[1]; procs()
    system("sleep 1")
    split(first("/proc/uptime"), u, " "); pdt = u[1] - pup3; out = ""; procs()
    print "{" substr(out, 2) "}"
    exit
  }
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

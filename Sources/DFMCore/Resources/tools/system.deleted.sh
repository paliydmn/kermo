#!/bin/sh
# System preset, Deleted Files Still Open on the disk $MOUNT (as root): files removed while a process still holds
# them — df counts their space, du doesn't, and it comes back only when that process closes them or ends. One JSON line
# each: the path it had, its size, and the process (pid, start, boot, command, kind, as the stream gives them), so Stop
# and Kill down there check the pid is still that process. Read-only: ls and stat over /proc.
# A file counts when it's on the file system of $MOUNT (the same device), not under another disk mounted inside it.
# A file's name could hold a line break and so a made-up "/proc/<pid>/fd:" line pointing at another process: GNU ls
# prints names as they are unless -q, busybox's has no -q and prints "?" anyway. Stop and Kill check the fd again.
# ponytail: a btrfs subvolume that isn't mounted on its own has a device of its own too — its files aren't listed;
# a server with more processes than one command line holds (ARG_MAX, about 100 000) lists none.
LC_ALL=C; export LC_ALL
dev=$(stat -c %d "$MOUNT") || exit 1
q=; ls -q / >/dev/null 2>&1 && q=q
ls -l$q /proc/[0-9]*/fd/ 2>/dev/null | exec awk -v dev="$dev" '
function rep(s, c, by,   n, p, i, r) { n = split(s, p, c); r = p[1]; for (i = 2; i <= n; i++) r = r by p[i]; return r }
function esc(s) { s = rep(s, "\\", "\\\\"); s = rep(s, "\"", "\\\""); gsub(ctl, " ", s); return s }

# /proc/<pid>/stat as one line — a name may hold a line break — and its fields after the name, which may hold ") ":
# s[1] state, s[2] parent, s[3] process group, s[5] terminal, s[7] flags, s[20] start. Its name goes to `name`; 0: it
# has ended. The same in system.stream.sh, with mine, under and kind: keep them alike.
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

/^\/proc\/[0-9]+\/fd\/?:$/ { pid = substr($0, 7); sub(/\/.*/, "", pid); next }   # "/proc/42/fd/:", as the argument was
/ \(deleted\)$/ {
  i = index($0, " -> "); if (!i || pid == "") next
  path = substr($0, i + 4); path = substr(path, 1, length(path) - 10)
  if (path !~ /^\// || path ~ /^\/memfd:/) next   # anonymous memory, not a file on a disk
  fd = substr($0, 1, i - 1); sub(/.* /, "", fd)
  n++; F[n] = "/proc/" pid "/fd/" fd; P[n] = pid; D[n] = fd; T[n] = path
}

END {
  ctl = sprintf("[%c-%c%c]", 1, 31, 127)
  getline l < "/proc/self/stat"; close("/proc/self/stat"); split(l, u, " "); me = u[1]   # opened by awk itself: its own pid
  getline boot < "/proc/sys/kernel/random/boot_id"; close("/proc/sys/kernel/random/boot_id")
  mine(); split("", s)
  for (i = 1; i <= n; i += 200) {   # one stat for 200 links: their device and size
    cmd = "stat -L -c \"%d %s %n\""
    for (j = i; j < i + 200 && j <= n; j++) cmd = cmd " " F[j]
    cmd = cmd " 2>/dev/null"
    while ((cmd | getline l) > 0) { split(l, a, " "); if (a[1] == dev) size[a[3]] = a[2] }
    close(cmd)
  }
  for (i = 1; i <= n; i++) {
    if (!(F[i] in size) || !stat(P[i], s)) continue
    nm = name; kd = kind(P[i], s[7], s[3], s[5])   # kind may read other processes: then name is theirs
    printf "{\"path\":\"%s\",\"size\":%.0f,\"pid\":%d,\"fd\":%d,\"start\":\"%s\",\"boot\":\"%s\",\"command\":\"%s\",\"kind\":\"%s\"}\n", \
      esc(T[i]), size[F[i]], P[i], D[i], s[20], substr(boot, 1, 8), esc(nm), kd
  }
}'

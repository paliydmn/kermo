#!/bin/sh
# A report of this machine for support. No root needed. GNU tools first, then what busybox and BSD have; a section
# with neither says so instead of staying empty.
h() { printf '\n== %s ==\n' "$1"; }
na() { echo "$1: not available here"; }
h Host
hostname
sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'
uname -srm
uptime
h CPU
if command -v lscpu >/dev/null 2>&1; then
  lscpu | grep -E '^(Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|CPU max MHz):'
elif [ -r /proc/cpuinfo ]; then
  sed -n 's/^model name[[:space:]]*:[[:space:]]*/Model name: /p' /proc/cpuinfo | head -1
  echo "CPU(s): $(grep -c '^processor' /proc/cpuinfo)"
else
  sysctl -n hw.model hw.ncpu 2>/dev/null || na CPU
fi
h Memory
free -h 2>/dev/null || free 2>/dev/null || na free
h Disks
df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -h
lsblk -d -o NAME,SIZE,ROTA,MODEL 2>/dev/null || na lsblk
h GPU
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv
elif command -v lspci >/dev/null 2>&1; then
  lspci | grep -iE 'vga|3d|display' || echo "none found"
else
  na lspci
fi
h Network
ip -br addr 2>/dev/null || ip addr 2>/dev/null || ifconfig 2>/dev/null || na ip
ip route 2>/dev/null | head -5
h "Top processes"
{ ps -eo pid,user,%cpu,%mem,etime,comm --sort=-%cpu 2>/dev/null || top -bn1 2>/dev/null; } | head -12
h "Failed services"
systemctl --failed --no-legend 2>/dev/null || echo "systemctl not here"

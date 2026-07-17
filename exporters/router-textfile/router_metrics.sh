#!/bin/bash
#
# router_metrics.sh - collect temperature, memory, and per-core CPU usage
# from a router (or any Linux box) over SSH, and write them as a
# Prometheus textfile-collector .prom file.
#
# Why SSH + textfile collector instead of a "real" exporter?
# Most consumer routers run a stripped-down Linux with no package manager
# and no room (or willingness from the vendor) to run node_exporter
# directly. But they almost always have `/proc` and an SSH daemon. This
# script does the minimum: SSH in, read a few /proc files, compute deltas
# for CPU usage, and write Prometheus-format output that node_exporter
# picks up from its textfile directory.
#
# Configuration (override via environment or a sourced config file):
#   ROUTER_HOST   - hostname/IP of the router (default: 192.168.1.1)
#   ROUTER_USER   - SSH user (default: admin)
#   ROUTER_PORT   - SSH port (default: 22)
#   SSH_KEY       - path to SSH private key (default: ~/.ssh/router_key)
#   CPU_CORES     - number of CPU cores to report (default: 4)
#   OUTPUT_FILE   - where to write the .prom file
#
# Schedule via cron (e.g. every minute):
#   * * * * * /usr/local/bin/router_metrics.sh
#
set -euo pipefail

ROUTER_HOST="${ROUTER_HOST:-192.168.1.1}"
ROUTER_USER="${ROUTER_USER:-admin}"
ROUTER_PORT="${ROUTER_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/router_key}"
CPU_CORES="${CPU_CORES:-4}"
OUTPUT_FILE="${OUTPUT_FILE:-/var/lib/prometheus/node-exporter/router_metrics.prom}"

SSH="ssh -i ${SSH_KEY} -p ${ROUTER_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${ROUTER_USER}@${ROUTER_HOST}"

# Temperature (millidegrees C -> degrees C)
TEMP=$($SSH 'cat /sys/class/thermal/thermal_zone0/temp' 2>/dev/null || echo 0)

# Memory (kB from /proc/meminfo -> bytes)
MEMINFO=$($SSH 'cat /proc/meminfo' 2>/dev/null || true)
MEM_TOTAL=$(echo "$MEMINFO" | awk '/^MemTotal:/ {print $2}')
MEM_FREE=$(echo "$MEMINFO" | awk '/^MemFree:/ {print $2}')
MEM_AVAIL=$(echo "$MEMINFO" | awk '/^MemAvailable:/ {print $2}')

# Per-core CPU usage via two /proc/stat samples one second apart
STAT1=$($SSH 'cat /proc/stat' 2>/dev/null || true)
sleep 1
STAT2=$($SSH 'cat /proc/stat' 2>/dev/null || true)

{
  echo "router_temperature_celsius $(echo "scale=2; $TEMP/1000" | bc)"
  echo "router_memory_total_bytes $(echo "${MEM_TOTAL:-0} * 1024" | bc)"
  echo "router_memory_free_bytes $(echo "${MEM_FREE:-0} * 1024" | bc)"
  echo "router_memory_available_bytes $(echo "${MEM_AVAIL:-0} * 1024" | bc)"

  for ((i = 0; i < CPU_CORES; i++)); do
    LINE1=$(echo "$STAT1" | grep "^cpu$i ")
    LINE2=$(echo "$STAT2" | grep "^cpu$i ")

    USER1=$(echo "$LINE1" | awk '{print $2}')
    NICE1=$(echo "$LINE1" | awk '{print $3}')
    SYS1=$(echo "$LINE1" | awk '{print $4}')
    IDLE1=$(echo "$LINE1" | awk '{print $5}')

    USER2=$(echo "$LINE2" | awk '{print $2}')
    NICE2=$(echo "$LINE2" | awk '{print $3}')
    SYS2=$(echo "$LINE2" | awk '{print $4}')
    IDLE2=$(echo "$LINE2" | awk '{print $5}')

    TOTAL1=$((USER1 + NICE1 + SYS1 + IDLE1))
    TOTAL2=$((USER2 + NICE2 + SYS2 + IDLE2))
    DTOTAL=$((TOTAL2 - TOTAL1))
    DIDLE=$((IDLE2 - IDLE1))

    if [ "$DTOTAL" -gt 0 ]; then
      CPU_USE=$(echo "scale=2; (1 - $DIDLE/$DTOTAL) * 100" | bc)
    else
      CPU_USE=0
    fi
    echo "router_cpu_usage_percent{core=\"cpu$i\"} $CPU_USE"
  done
} > "${OUTPUT_FILE}.tmp"

# Atomic rename so node_exporter never reads a half-written file
mv "${OUTPUT_FILE}.tmp" "${OUTPUT_FILE}"

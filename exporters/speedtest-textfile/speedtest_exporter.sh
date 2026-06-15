#!/bin/bash
#
# speedtest_exporter.sh — run `speedtest` (Ookla CLI) and write the
# results as a Prometheus textfile-collector .prom file.
#
# Configuration:
#   SPEEDTEST_BIN - full path to the speedtest binary (see note below)
#   OUTPUT_FILE   - where to write the .prom file
#
# IMPORTANT — run this as a regular user, not as the `prometheus` user
# or any other service account:
#
#   Ookla's speedtest.net backend returns HTTP 403 to requests from some
#   service-account-like environments (observed with the `prometheus`
#   user on Debian/Raspberry Pi OS, even with identical network access).
#   Running the exact same binary as a normal interactive user works
#   fine. If your metrics file is empty/stale and the script "works when
#   I run it manually", check *which user* your cron job runs as.
#
# Also note: cron's PATH is minimal and usually does NOT include
# ~/.local/bin, where pip/official installers often put `speedtest`. Use
# the full path (find it with `which speedtest` as the user that will run
# the cron job).
#
# Schedule via the target user's crontab (NOT root's):
#   55 * * * * SPEEDTEST_BIN=/home/youruser/.local/bin/speedtest /usr/local/bin/speedtest_exporter.sh
#
set -euo pipefail

SPEEDTEST_BIN="${SPEEDTEST_BIN:-$HOME/.local/bin/speedtest}"
OUTPUT_FILE="${OUTPUT_FILE:-/var/lib/prometheus/node-exporter/speedtest.prom}"

if [ ! -x "$SPEEDTEST_BIN" ]; then
  echo "speedtest binary not found or not executable: $SPEEDTEST_BIN" >&2
  exit 1
fi

JSON=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr -f json 2>/dev/null)

DOWNLOAD_BPS=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['download']['bandwidth'] * 8)")
UPLOAD_BPS=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['upload']['bandwidth'] * 8)")
PING_MS=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['ping']['latency'])")
JITTER_MS=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['ping']['jitter'])")
SERVER_ID=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['server']['id'])")
SERVER_NAME=$(echo "$JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['server']['name'])")

{
  echo "# HELP speedtest_download_bits_per_second Download speed in bits/sec"
  echo "# TYPE speedtest_download_bits_per_second gauge"
  echo "speedtest_download_bits_per_second{server_id=\"$SERVER_ID\",server_name=\"$SERVER_NAME\"} $DOWNLOAD_BPS"

  echo "# HELP speedtest_upload_bits_per_second Upload speed in bits/sec"
  echo "# TYPE speedtest_upload_bits_per_second gauge"
  echo "speedtest_upload_bits_per_second{server_id=\"$SERVER_ID\",server_name=\"$SERVER_NAME\"} $UPLOAD_BPS"

  echo "# HELP speedtest_ping_latency_ms Ping latency in milliseconds"
  echo "# TYPE speedtest_ping_latency_ms gauge"
  echo "speedtest_ping_latency_ms{server_id=\"$SERVER_ID\",server_name=\"$SERVER_NAME\"} $PING_MS"

  echo "# HELP speedtest_jitter_ms Jitter in milliseconds"
  echo "# TYPE speedtest_jitter_ms gauge"
  echo "speedtest_jitter_ms{server_id=\"$SERVER_ID\",server_name=\"$SERVER_NAME\"} $JITTER_MS"
} > "${OUTPUT_FILE}.tmp"

mv "${OUTPUT_FILE}.tmp" "${OUTPUT_FILE}"

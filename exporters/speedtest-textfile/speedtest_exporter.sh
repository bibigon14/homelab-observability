#!/bin/bash
# Speedtest → Prometheus node_exporter textfile collector.
# Uses official Ookla CLI (speedtest, not the unmaintained Python wrapper).
# Bandwidth in Ookla's JSON is bytes/sec; we expose Mbit/s for compatibility
# with the existing Grafana panels (multiply by 8 / 1_000_000).

set -euo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin

OUTFILE="/var/lib/prometheus/node-exporter/speedtest.prom"
LOGFILE="/home/bibigon88/speedtest.log"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if ! /usr/bin/speedtest --accept-license --accept-gdpr --format=json > "$TMP" 2>>"$LOGFILE"; then
    echo "$(date -Iseconds) ERROR: speedtest failed" >> "$LOGFILE"
    exit 1
fi

# Validate it's a result, not an error envelope
if ! /usr/bin/jq -e '.type == "result"' "$TMP" > /dev/null 2>&1; then
    echo "$(date -Iseconds) ERROR: unexpected output: $(cat "$TMP")" >> "$LOGFILE"
    exit 1
fi

/usr/bin/jq -r '
  "speedtest_ping_ms \(.ping.latency)",
  "speedtest_ping_jitter_ms \(.ping.jitter)",
  "speedtest_download_mbps \(.download.bandwidth * 8 / 1000000)",
  "speedtest_upload_mbps \(.upload.bandwidth * 8 / 1000000)",
  "speedtest_download_latency_ms \(.download.latency.iqm)",
  "speedtest_upload_latency_ms \(.upload.latency.iqm)",
  "speedtest_packet_loss_ratio \(.packetLoss // 0)",
  "speedtest_last_run_timestamp_seconds \(now)"
' "$TMP" > "$OUTFILE.tmp"

# Add HELP/TYPE headers, then atomically move into place
{
  cat <<HEADERS
# HELP speedtest_ping_ms Latency (ping) to nearest Ookla server, in milliseconds
# TYPE speedtest_ping_ms gauge
# HELP speedtest_ping_jitter_ms Ping jitter, in milliseconds
# TYPE speedtest_ping_jitter_ms gauge
# HELP speedtest_download_mbps Download bandwidth, megabits per second
# TYPE speedtest_download_mbps gauge
# HELP speedtest_upload_mbps Upload bandwidth, megabits per second
# TYPE speedtest_upload_mbps gauge
# HELP speedtest_download_latency_ms Loaded-download latency (IQM), milliseconds
# TYPE speedtest_download_latency_ms gauge
# HELP speedtest_upload_latency_ms Loaded-upload latency (IQM), milliseconds
# TYPE speedtest_upload_latency_ms gauge
# HELP speedtest_packet_loss_ratio Fraction of packets lost (0.0 - 1.0)
# TYPE speedtest_packet_loss_ratio gauge
# HELP speedtest_last_run_timestamp_seconds Unix timestamp of last successful run
# TYPE speedtest_last_run_timestamp_seconds gauge
HEADERS
  cat "$OUTFILE.tmp"
} > "$OUTFILE.new"

mv -f "$OUTFILE.new" "$OUTFILE"
rm -f "$OUTFILE.tmp"

echo "$(date -Iseconds) OK: ping=$(/usr/bin/jq -r '.ping.latency' "$TMP")ms" >> "$LOGFILE"

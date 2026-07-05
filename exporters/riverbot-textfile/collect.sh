#!/bin/bash
OUTFILE="/var/lib/prometheus/node-exporter/riverbot.prom"
PID=$(systemctl show riverbot.service --property=MainPID --value 2>/dev/null | tr -d '[:space:]')
python3 /home/bibigon88/homelab-observability/exporters/riverbot-textfile/collect.py "$PID" > "${OUTFILE}.tmp" && mv "${OUTFILE}.tmp" "$OUTFILE"

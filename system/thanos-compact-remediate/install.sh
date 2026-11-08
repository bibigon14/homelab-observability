#!/usr/bin/env bash
# Idempotent installer for the thanos-compact auto-remediation stack.
#
# Copies the remediation script to /usr/local/bin and the systemd
# service + timer units to /etc/systemd/system, reloads systemd, enables
# the timer and prints the resulting state. Safe to re-run: every step
# is idempotent and only the units are started, so repeated installs do
# not disturb a running timer.
#
# Why this exists: the script and unit files have drifted in production
# before (10-12: new script version deployed, systemd unit nowhere to be
# found, timer silently absent -> ThanosAutoRemediateGaveUp fired until
# 10-14 when it was noticed). This installer plus the sibling Makefile
# make that drift impossible by shipping the two together as one step.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$HERE/thanos-compact-auto-remediate"
SERVICE_SRC="$HERE/thanos-compact-remediate.service"
TIMER_SRC="$HERE/thanos-compact-remediate.timer"

BIN_DST="/usr/local/bin/thanos-compact-auto-remediate"
SERVICE_DST="/etc/systemd/system/thanos-compact-remediate.service"
TIMER_DST="/etc/systemd/system/thanos-compact-remediate.timer"

# Sanity: every source file we expect to install must exist.
for f in "$BIN_SRC" "$SERVICE_SRC" "$TIMER_SRC"; do
    if [ ! -f "$f" ]; then
        echo "error: missing source file: $f" >&2
        exit 1
    fi
done

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (writes to /usr/local/bin and /etc/systemd/system)" >&2
    exit 1
fi

echo "==> installing script -> $BIN_DST"
install -m 0755 "$BIN_SRC" "$BIN_DST"

echo "==> installing unit files -> /etc/systemd/system"
install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
install -m 0644 "$TIMER_SRC" "$TIMER_DST"

echo "==> systemctl daemon-reload"
systemctl daemon-reload

echo "==> enabling and starting thanos-compact-remediate.timer"
systemctl enable --now thanos-compact-remediate.timer

echo
echo "==> installed state:"
systemctl list-timers thanos-compact-remediate.timer --no-pager | sed 's/^/  /'
echo
systemctl status thanos-compact-remediate.timer --no-pager | head -8 | sed 's/^/  /'
echo
echo "==> next step: wait up to 2 minutes, then run"
echo "     sudo systemctl status thanos-compact-remediate.service"
echo "   to see the first remediation evaluation."

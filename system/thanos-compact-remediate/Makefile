# Operational entrypoints for the thanos-compact auto-remediation stack.
#
# `make install` keeps the script and its systemd units in sync - a drift
# between the two is exactly what let ThanosAutoRemediateGaveUp fire for
# 48h unnoticed in Oct 2026. Every other target is a safe read.

.PHONY: help install uninstall status journal dry-run test

help:
	@echo "targets:"
	@echo "  make install       - install script + service + timer (requires sudo)"
	@echo "  make uninstall     - stop timer, remove installed files (requires sudo)"
	@echo "  make status        - show timer + last service run status"
	@echo "  make journal       - tail journal for this unit"
	@echo "  make dry-run       - run the script once without side effects (set DRY_RUN=1)"
	@echo "  make test          - replay recorded 10/12 journal line through the script"

install:
	@sudo ./install.sh

uninstall:
	@sudo systemctl disable --now thanos-compact-remediate.timer 2>/dev/null || true
	@sudo rm -f /usr/local/bin/thanos-compact-auto-remediate
	@sudo rm -f /etc/systemd/system/thanos-compact-remediate.service
	@sudo rm -f /etc/systemd/system/thanos-compact-remediate.timer
	@sudo systemctl daemon-reload
	@echo "uninstalled."

status:
	@systemctl list-timers thanos-compact-remediate.timer --no-pager || true
	@echo
	@systemctl status thanos-compact-remediate.service --no-pager || true

journal:
	@journalctl -u thanos-compact-remediate.service --no-pager -n 50 || true

dry-run:
	@DRY_RUN=1 sudo ./thanos-compact-auto-remediate

test:
	@echo "replaying recorded 10/12 downsample error through the script:"
	@echo "expected BLOCK_ID=01M4SHDRMR30GPQTCKPSBK8QKT MARKER=no-downsample-mark.json"
	@if [ -f testdata/thanos-0.42-downsample-error.log ]; then \
	    DRY_RUN=1 FIXTURE=testdata/thanos-0.42-downsample-error.log \
	        ./thanos-compact-auto-remediate; \
	else \
	    echo "testdata/thanos-0.42-downsample-error.log not present; skip"; \
	fi

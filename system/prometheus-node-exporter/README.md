# prometheus-node-exporter

Debian package `prometheus-node-exporter` provides the hardened
systemd unit and package infrastructure; upstream tarball
provides the actual binary. Same hybrid pattern as Prometheus.

## Runtime

- **Version**: 1.12.1 (upstream tarball, linux-arm64)
- **Binary**: `/opt/node_exporter/node_exporter`
- **Systemd unit**: from Debian package (kept for hardening),
  `ExecStart` overridden via drop-in.
- **apt-mark hold**ed to prevent apt from touching the binary.
- **Collectors**: defaults - no customization needed for a Pi.
- **Textfile directory**: `/var/lib/prometheus/node-exporter`
  (from Debian package default, kept as-is).

## Override

`override.conf` adds:

- `Restart=on-failure` / `RestartSec=5s` - not in the package
  default; ensures the exporter comes back after transient failures.
- `ExecStart=` (clear) + `ExecStart=/opt/node_exporter/node_exporter $ARGS`
  - swaps the binary path from `/usr/bin/prometheus-node-exporter`
  to the upstream tarball while keeping the `$ARGS` from
  `/etc/default/prometheus-node-exporter`.

## Install

    # 1. Base package (unit + hardening + textfile collectors)
    sudo apt install prometheus-node-exporter prometheus-node-exporter-collectors

    # 2. Upstream binary
    curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.12.1/node_exporter-1.12.1.linux-arm64.tar.gz
    tar xzf node_exporter-1.12.1.linux-arm64.tar.gz
    sudo mkdir -p /opt/node_exporter
    sudo cp node_exporter-1.12.1.linux-arm64/node_exporter /opt/node_exporter/
    sudo chown root:root /opt/node_exporter/node_exporter

    # 3. Drop-in override
    sudo mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
    sudo cp override.conf /etc/systemd/system/prometheus-node-exporter.service.d/

    # 4. Hold apt, reload systemd, restart
    sudo apt-mark hold prometheus-node-exporter
    sudo systemctl daemon-reload
    sudo systemctl restart prometheus-node-exporter

    # 5. Verify
    curl -s http://localhost:9100/metrics | grep '^node_exporter_build_info'

## History

- 2026-07-16: initial install (Debian package, 1.9.0)
- 2026-09-06: hybrid apt + tarball, 1.9.0 -> 1.12.1

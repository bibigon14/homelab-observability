# alertmanager

Bare-metal Alertmanager for the Raspberry Pi 5 homelab.

## Runtime

- **Version**: 0.34.0 (upstream tarball, linux-arm64)
- **Binary**: `/usr/local/bin/alertmanager` + `/usr/local/bin/amtool`
- **Config**: `/etc/alertmanager/alertmanager.yml` (this repo: `alertmanager.yml`)
- **Systemd unit**: `/etc/systemd/system/alertmanager.service` (this
  repo: `alertmanager.service`) - hand-rolled, not from a Debian
  package (there is none for Alertmanager in Debian trixie).
- **Storage**: `/var/lib/alertmanager` (silences, notification log)
- **User**: bibigon88 (predates any hardening thoughts)
- **Ports**: 9093 (HTTP API + UI), 9094 (cluster gossip; unused,
  single-node)

## Routing

Single receiver `telegram-bridge` webhooks to
`http://localhost:30119/webhook`, which is the
`alertmanager-telegram-bridge` app in the k8s `apps` namespace.
That app holds the actual Telegram bot token in its k8s Secret;
this config has no credentials.

Muted alerts (routed to `null` receiver):

- `PrometheusCheckpointFailing` - upstream bug
  prometheus/prometheus#16074 recurred every ~2h under 2.53.3.
  Muted 2026-09-06 pending Prometheus 3.14 upgrade evaluation.
  Metric stays visible in Grafana for trend tracking.

## Install (fresh box)

    # 1. Download binary
    curl -LO https://github.com/prometheus/alertmanager/releases/download/v0.34.0/alertmanager-0.34.0.linux-arm64.tar.gz
    tar xzf alertmanager-0.34.0.linux-arm64.tar.gz
    sudo cp alertmanager-0.34.0.linux-arm64/{alertmanager,amtool} /usr/local/bin/
    sudo chown root:root /usr/local/bin/{alertmanager,amtool}
    sudo chmod 755 /usr/local/bin/{alertmanager,amtool}

    # 2. Directories
    sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
    sudo chown bibigon88 /var/lib/alertmanager

    # 3. Config + unit from this repo
    sudo cp alertmanager.yml /etc/alertmanager/
    sudo cp alertmanager.service /etc/systemd/system/

    # 4. Enable + start
    sudo systemctl daemon-reload
    sudo systemctl enable --now alertmanager
    curl -s http://localhost:9093/api/v2/status | jq '.versionInfo'

## Upgrade binary

    # Download new tarball, then:
    sudo systemctl stop alertmanager
    sudo cp alertmanager amtool /usr/local/bin/
    amtool check-config /etc/alertmanager/alertmanager.yml
    sudo systemctl start alertmanager
    curl -s http://localhost:9093/api/v2/status | jq '.versionInfo'

## Update config

    sudo cp alertmanager.yml /etc/alertmanager/
    amtool check-config /etc/alertmanager/alertmanager.yml
    sudo curl -X POST http://localhost:9093/-/reload

## History

- 2026-07-14: initial install (0.27.0), systemd unit hand-rolled
- 2026-09-06: unit + config vendored into git after being
  discovered as another Pi-only artifact
- 2026-09-06: upgraded 0.27.0 -> 0.34.0

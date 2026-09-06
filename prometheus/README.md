# prometheus

Bare-metal Prometheus config for the Raspberry Pi 5 homelab.
Deployed to `/etc/prometheus/prometheus.yml`; rules live in
`../alerting/*.yml` and are deployed to `/etc/prometheus/rules/`.

## Runtime

Bare-metal systemd unit (v2.53.3 from Debian sid, arm64), not
in k8s. TSDB path `/var/lib/prometheus/metrics2` (non-default).
Daily restart bug workaround: see `../system/prometheus-daily-restart/`.

Command-line args (from systemd unit):

    --web.enable-admin-api
    --storage.tsdb.min-block-duration=2h
    --storage.tsdb.max-block-duration=2h

Both block-duration flags are required for the Thanos sidecar.

## Scrape targets

- Local exporters: node, pihole, cadvisor, kube-state-metrics
- k8s NodePort apps: argocd, bridge, wc2026bot, riverbot, demo-app
- Thanos stack: sidecar, store, query, compact
- Blackbox probes: internal https (`*.homelab.local`), external
  http (USGS waterservices), DNS (127.0.0.1:53 via Pi-hole)

## External labels (for Thanos)

    monitor: homebridge
    location: home

## Install / update

    sudo cp prometheus.yml /etc/prometheus/prometheus.yml
    sudo promtool check config /etc/prometheus/prometheus.yml
    sudo curl -X POST http://localhost:9090/-/reload

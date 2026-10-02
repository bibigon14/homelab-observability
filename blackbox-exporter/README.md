# Blackbox Exporter

## Deployment

- Package: Debian apt (`blackbox_exporter`), not upstream tarball
- Binary: `/usr/bin/blackbox_exporter`
- Config: `/etc/blackbox_exporter/blackbox.yml` (owned by apt package)
- Service: `blackbox_exporter.service` (enabled, active)
- Listen: `localhost:9115`

Unlike Prometheus/Thanos/Node Exporter which use a hybrid apt (service unit)
+ upstream tarball (binary) pattern, Blackbox stays fully on the Debian
package. Version in use (0.28) is current enough that no manual override
is needed.

## Modules

- `http_2xx` - public HTTPS (external targets with public CA, e.g. USGS)
- `https_homelab` - internal `*.homelab.local` (self-signed Homelab CA)
- `dns_pihole_homelab` - DNS probe against Pi-hole on 127.0.0.1:53

## Scraped by

Prometheus jobs `blackbox-homelab-https`, `blackbox-external-http`,
`blackbox-dns-homelab` (see `../prometheus/prometheus.yml`).

Runbook: `../../homelab-k3s/docs/runbooks/ingress-health-check.md`.

## Sync

Pi is the source of truth for the live file. This repo is manual catch-up,
not auto-synced. Changes: edit here, review diff, scp to Pi, reload service.

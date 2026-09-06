# alertmanager

Bare-metal Alertmanager config for the Raspberry Pi 5 homelab.
Deployed to `/etc/alertmanager/alertmanager.yml`.

## Runtime

Bare-metal systemd unit, not in k8s. Running since 2026-07-14.

## Routing

Single receiver `telegram-bridge` webhooks to
`http://localhost:30119/webhook`, which is the
`alertmanager-telegram-bridge` app in the k8s `apps` namespace.
That app holds the actual Telegram bot token in its k8s Secret;
this config has no credentials.

Muted alerts (routed to `null` receiver):

- `PrometheusCheckpointFailing` - upstream bug
  prometheus/prometheus#16074 recurs every ~2h regardless of
  daily restart (confirmed 2026-09-06). Metric stays visible
  in Grafana for trend tracking; alert is silenced until
  upgrade attempt to Prometheus 3.x resolves or reduces rate.

## Install / update

    sudo cp alertmanager.yml /etc/alertmanager/alertmanager.yml
    amtool check-config /etc/alertmanager/alertmanager.yml
    sudo curl -X POST http://localhost:9093/-/reload

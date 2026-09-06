# prometheus-node-exporter

Debian package `prometheus-node-exporter` (currently 1.9.0-1+b4
on trixie) provides the binary and hardened systemd unit.
Only the systemd drop-in override is customized.

## Override

`override.conf` adds:

- `Restart=on-failure` - default in the package is unset, this
  ensures node_exporter comes back after transient failures
- `RestartSec=5s` - throttle to avoid tight restart loops

No collector customization - defaults are sufficient (274
metrics exposed, all the standard collectors).

## Install

    sudo apt install prometheus-node-exporter prometheus-node-exporter-collectors
    sudo mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
    sudo cp override.conf /etc/systemd/system/prometheus-node-exporter.service.d/
    sudo systemctl daemon-reload
    sudo systemctl restart prometheus-node-exporter

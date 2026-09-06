# prometheus

Bare-metal Prometheus for the Raspberry Pi 5 homelab.

## Runtime

- **Version**: 3.14.0 (upstream tarball, linux-arm64)
- **Binary**: `/opt/prometheus/prometheus`
- **Config**: `/etc/prometheus/prometheus.yml` (this repo: `prometheus.yml`)
- **Rules**: `/etc/prometheus/rules/*.yml` (this repo: `../alerting/`)
- **TSDB**: `/var/lib/prometheus/metrics2` (non-default, kept for
  continuity from the original box setup)
- **Systemd unit**: from the Debian `prometheus` package (all its
  hardening options), with `ExecStart` overridden via drop-in to
  point at the tarball binary. Package is `apt-mark hold`ed so
  `apt upgrade` won't replace the binary.

Runs alongside Thanos sidecar (`../system/thanos/`) which ships
2h blocks to Cloudflare R2.

## Why the hybrid install (apt package + tarball binary)

Debian trixie stable ships Prometheus 2.53.3 and won't move -
Debian sid is stagnant here. Upstream is on 3.x. To get modern
Prometheus without losing the Debian systemd hardening:

1. `apt install prometheus` gives us `/usr/lib/systemd/system/prometheus.service`
   with `PrivateTmp`, `ProtectHome`, `ProtectSystem=full`,
   `MemoryDenyWriteExecute`, capability drops, and other
   security defaults we'd otherwise have to hand-roll.
2. Tarball binary in `/opt/prometheus/` runs the actual version.
3. `systemctl edit` drop-in swaps `ExecStart` to the tarball.
4. `apt-mark hold prometheus` prevents apt from overwriting.

## Flags (in `prometheus.defaults`, sourced by systemd unit)

    --config.file=/etc/prometheus/prometheus.yml
    --web.enable-admin-api
    --web.enable-lifecycle
    --storage.tsdb.path=/var/lib/prometheus/metrics2
    --storage.tsdb.delay-compact-file.path=/var/lib/prometheus/metrics2/thanos.shipper.json

The last flag coordinates with Thanos sidecar so Prometheus
delays higher-level compactions until Thanos has uploaded the
2h block to object storage. The path MUST match what Thanos
sidecar computes internally:

- Thanos 0.42+ compares path strings literally, so pass the
  **absolute** path here (matches sidecar's `<tsdb.path>/thanos.shipper.json`).
- Thanos 0.41 and earlier resolved both sides and compared
  results, so a relative filename worked too.

We're on 0.42.4 - absolute path is required. A relative path
causes the sidecar to fail startup validation with a misleading
"different paths" error.

## Prometheus 3.x migration notes (from 2.53.3)

Removed flags we had to drop:

- `--storage.tsdb.min-block-duration=2h` / `--storage.tsdb.max-block-duration=2h`
  removed. Default block duration is still 2h (Thanos sidecar
  requirement satisfied). Coordination with Thanos now happens
  through `--storage.tsdb.delay-compact-file.path` instead.
- `--storage.tsdb.wal-compression` removed. WAL compression is
  always on in 3.x; use `--storage.tsdb.wal-compression-type=zstd`
  to switch from default snappy.

New required flag we had to add:

- `--config.file=/etc/prometheus/prometheus.yml` - the Debian
  package relied on a compiled-in default that pointed here;
  the upstream tarball has no such default and looks in the
  working directory.

## Install (fresh box)

    # 1. Base systemd unit with hardening from Debian
    sudo apt install prometheus

    # 2. Upstream binary
    curl -LO https://github.com/prometheus/prometheus/releases/download/v3.14.0/prometheus-3.14.0.linux-arm64.tar.gz
    tar xzf prometheus-3.14.0.linux-arm64.tar.gz
    sudo mkdir -p /opt/prometheus
    sudo cp prometheus-3.14.0.linux-arm64/{prometheus,promtool} /opt/prometheus/
    sudo chown -R root:root /opt/prometheus

    # 3. Config + args + rules from this repo
    sudo cp prometheus.yml /etc/prometheus/prometheus.yml
    sudo cp prometheus.defaults /etc/default/prometheus
    sudo mkdir -p /etc/systemd/system/prometheus.service.d
    sudo cp systemd-override/override.conf \
      /etc/systemd/system/prometheus.service.d/
    sudo cp ../alerting/*.yml /etc/prometheus/rules/

    # 4. Freeze apt package, reload systemd, start
    sudo apt-mark hold prometheus
    sudo systemctl daemon-reload
    sudo systemctl restart prometheus.service

    # 5. Verify
    curl -s localhost:9090/api/v1/status/buildinfo | jq .

## Upgrade Prometheus binary

    # Download and unpack new tarball, then:
    sudo cp prometheus promtool /opt/prometheus/
    sudo systemctl restart prometheus.service
    curl -s localhost:9090/api/v1/status/buildinfo | jq .

If new version removes or renames flags, update `prometheus.defaults`
in this repo first, sync to Pi, then restart.

## History

- 2026-09-06 08:12 PDT: upgraded 2.53.3 -> 3.14.0. Initial
  attempt used a relative path for `delay-compact-file` because
  Thanos 0.41 accepted it.
- 2026-09-06 09:53 PDT: upgraded Thanos 0.41 -> 0.42.4. New
  Thanos does literal string comparison of the path, so we had
  to switch Prometheus to the absolute path shown above.

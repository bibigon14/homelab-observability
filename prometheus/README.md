# prometheus

Bare-metal Prometheus for the Raspberry Pi 5 homelab.

## Runtime

- **Version**: 3.14.0 (upstream tarball, linux-arm64)
- **Binary**: `/opt/prometheus/prometheus`
- **Config**: `/etc/prometheus/prometheus.yml` (this repo: `prometheus.yml`)
- **Rules**: `/etc/prometheus/rules/*.yml` (this repo: `../alerting/`)
- **TSDB**: `/var/lib/prometheus/metrics2` (non-default, chosen when
  the box was set up; kept for continuity)
- **Systemd unit**: from the Debian `prometheus` package (all its
  hardening options), with `ExecStart` overridden via drop-in to
  point at the tarball binary. Package is `apt-mark hold`ed so
  `apt upgrade` won't replace the binary.

Runs alongside Thanos sidecar (`thanos-sidecar.service`) which
ships 2h blocks to Cloudflare R2.

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
    --storage.tsdb.delay-compact-file.path=thanos.shipper.json

Note the last flag is **relative** - Prometheus resolves it
against `--storage.tsdb.path`. Thanos sidecar uses the same
default filename (`thanos.shipper.json`) inside its `--tsdb.path`,
and validates that both processes agree on the path string;
passing an absolute path here causes a mismatch error at Thanos
startup even though both processes are pointing at the same file.

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

- 2026-09-06: upgraded 2.53.3 -> 3.14.0 in response to WAL
  checkpoint bug (upstream #16074) recurring every ~2h despite
  the daily restart workaround. 3.x has TSDB read-path
  improvements that may reduce recurrence rate; result to be
  measured over subsequent compaction cycles.

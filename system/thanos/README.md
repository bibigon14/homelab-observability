# thanos

Bare-metal Thanos stack for the Raspberry Pi 5 homelab.
Four systemd units share a single `/usr/local/bin/thanos`
binary but run different subcommands.

## Runtime

- **Version**: 0.42.4 (upstream tarball, linux-arm64)
- **Binary**: `/usr/local/bin/thanos`
- **Object store config**: `/etc/thanos/objstore.yml`
  (**NOT vendored** - contains R2 credentials; template at
  `objstore.example.yml`)
- **User**: `prometheus` (systemd unit User=)
- **Data dirs**: per-service, under `/var/lib/thanos/*`

## Services

| Unit | Port(s) | Purpose |
|------|---------|---------|
| `thanos-sidecar` | 19191 http, 10901 gRPC | Ships 2h blocks from Prometheus to R2 |
| `thanos-store` | 19192 http, 10905 gRPC | Serves historical blocks from R2 to Query |
| `thanos-query` | 19193 http | Federated query across sidecar + store |
| `thanos-compact` | 19194 http | Background compaction and downsampling in R2 |

Prometheus scrape config includes all four - see `../../prometheus/prometheus.yml`.

## Path coordination with Prometheus

Since Thanos 0.42.x, `thanos sidecar` compares its internal
`<tsdb.path>/thanos.shipper.json` (from `--tsdb.path`) with
Prometheus's `--storage.tsdb.delay-compact-file.path` by literal
string. Both must be the same absolute path or sidecar refuses
to start. See `../../prometheus/README.md` for details.

## Install (fresh box)

    # 1. Binary
    curl -LO https://github.com/thanos-io/thanos/releases/download/v0.42.4/thanos-0.42.4.linux-arm64.tar.gz
    tar xzf thanos-0.42.4.linux-arm64.tar.gz
    sudo cp thanos-0.42.4.linux-arm64/thanos /usr/local/bin/
    sudo chown root:root /usr/local/bin/thanos

    # 2. Object store config (fill in real credentials from Cloudflare R2)
    sudo mkdir -p /etc/thanos
    sudo cp objstore.example.yml /etc/thanos/objstore.yml
    sudo chmod 640 /etc/thanos/objstore.yml
    sudo chown prometheus:prometheus /etc/thanos/objstore.yml
    sudo vim /etc/thanos/objstore.yml  # replace <ACCESS_KEY> and <SECRET_KEY>

    # 3. Data directories
    sudo mkdir -p /var/lib/thanos/{store,compact}
    sudo chown -R prometheus:prometheus /var/lib/thanos

    # 4. Systemd units
    sudo cp thanos-*.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now thanos-store thanos-compact
    sleep 3
    sudo systemctl enable --now thanos-sidecar thanos-query

    # 5. Verify
    for p in 19191 19192 19193 19194; do
      curl -s http://localhost:$p/-/ready && echo " :$p"
    done

## Upgrade binary

    # Download new tarball, then stop all, replace, start all:
    sudo systemctl stop thanos-sidecar thanos-compact thanos-store thanos-query
    sudo cp thanos /usr/local/bin/
    sudo systemctl start thanos-store thanos-compact
    sleep 3
    sudo systemctl start thanos-sidecar thanos-query

    # Check for breaking changes in flags/path handling for any
    # config file coordination (e.g. delay-compact-file path
    # semantics changed between 0.41 and 0.42).

## Rotate R2 credentials

    # 1. In Cloudflare Dashboard: revoke old token, create new
    # 2. Update file:
    sudo vim /etc/thanos/objstore.yml

    # 3. Restart the three daemons that use objstore
    #    (query has no objstore, don't need to restart)
    sudo systemctl restart thanos-sidecar thanos-compact thanos-store

    # 4. Verify no auth failures
    curl -sG 'http://localhost:9090/api/v1/query' \
      --data-urlencode 'query=sum by (operation) (thanos_objstore_bucket_operation_failures_total)' | \
      jq '.data.result'

## History

- 2026-06-24: initial install, Thanos 0.41.0
- 2026-09-06: upgraded 0.41 -> 0.42.4. Required Prometheus
  `delay-compact-file.path` switch from relative to absolute.

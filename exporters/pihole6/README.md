# pihole6-exporter

A minimal Prometheus exporter for **Pi-hole v6+**, which replaced the
static API-token auth used by v5 with session-based authentication.

See [`../../docs/postmortems/2026-06-02-pihole-v6-exporter-outage.md`](../../docs/postmortems/2026-06-02-pihole-v6-exporter-outage.md)
for the full story of how an in-place Pi-hole v5 → v6 upgrade silently
broke an existing exporter, and what changed in the API.

## What changed between v5 and v6 (the parts that bite exporters)

| | v5 | v6 |
|---|---|---|
| Auth | static token: `GET /admin/api.php?auth=<token>` | session: `POST /api/auth` with password → `sid`, then `X-FTL-SID` header on subsequent requests |
| Summary stats | `/admin/api.php?summary` | `GET /api/stats/summary` |
| Query types | flat structure | `GET /api/stats/query_types` → `{"types": {"A": n, "AAAA": n, ...}}` (a **dict**, not a list - code written against v5 that does `for item in query_types: item["name"]` will break or silently report nothing) |

Sessions also have a `webserver.api.max_sessions` limit - an exporter
that authenticates on every scrape (rather than reusing a session) can
exhaust this and start getting locked out, which looks like an
intermittent auth failure rather than a config problem.

## Setup

```bash
sudo cp pihole6_exporter.py /usr/local/bin/
sudo cp pihole6_exporter.service /etc/systemd/system/

sudo tee /etc/pihole6_exporter.env <<'EOF'
PIHOLE_HOST=localhost
PIHOLE_PASSWORD=your-pihole-web-password
EXPORTER_PORT=9617
EOF
sudo chmod 600 /etc/pihole6_exporter.env

sudo systemctl daemon-reload
sudo systemctl enable --now pihole6_exporter
sudo systemctl status pihole6_exporter
```

Add to `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: pihole6
    static_configs:
      - targets: ["localhost:9617"]
```

## Verifying it's actually working

```bash
curl -s http://localhost:9617/metrics | grep ^pihole_
```

If you see `pihole_query_by_type{type="A"} 0` for everything (but
Pi-hole's own admin UI shows real traffic), check:

1. Is `PIHOLE_PASSWORD` actually current? Pi-hole's CLI password
   (`/etc/pihole/cli_pw`) can rotate on certain operations - if your
   exporter reads it from there, a stale copy will authenticate
   successfully but then return empty/zeroed stats for some endpoints.
2. Is something else (another exporter, a stale systemd unit pointing at
   a different port) shadowing this one in Grafana? Check which
   Prometheus job your dashboard panels actually query, and confirm
   Prometheus's default datasource in Grafana hasn't silently changed
   (e.g. to InfluxDB) after adding other datasources.

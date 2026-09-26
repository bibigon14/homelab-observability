# prometheus-oci - HA replica on Oracle Cloud Ampere A1

Prometheus HA replica B, paired with the primary on the Raspberry Pi
homelab (replica A). Runs on the same OCI Ampere A1 VM that hosts
[`ebpf-tcp-observer`](https://github.com/bibigon14/ebpf-tcp-observer).

## Why this exists

Upstream bug [prometheus/prometheus#16074](https://github.com/prometheus/prometheus/issues/16074)
corrupts a WAL segment during the 2h checkpoint cycle. Any restart
after that (needed to reclaim WAL disk) truncates every segment newer
than the corrupt one - up to two hours of head data is erased
retroactively.

Single-instance Prometheus can't hide this. A daily restart timer
turned the retroactive loss into a predictable ~65 min daily gap; that
was disabled 2026-09-16 after the postmortem, but leaving the WAL to
grow unbounded is not viable either.

Two Prometheus replicas scraping the same targets, both shipping to
the same Thanos R2 bucket, let Thanos Query merge them at read time.
When either replica has a gap (from a restart, WAL truncation, host
outage, or a network blip), the other covers - Grafana shows
continuous data.

See [../../docs/adr/2026-09-25-ha-prometheus-oci-replica.md](../../docs/adr/2026-09-25-ha-prometheus-oci-replica.md)
for the trade-off analysis and why OCI over WG rather than a second
Pi or full VictoriaMetrics migration.

## How it fits together

```
                             +------------------+
                             |    Grafana       |
                             +---------+--------+
                                       |
                             +---------v--------+
                             |  Thanos Query    |  --query.replica-label=replica
                             |  (on Pi)         |
                             +---------+--------+
                                       |
              +------------+-----------+------------+
              |            |                        |
       +------v-----+  +---v-----+          +-------v---------+
       |  Thanos    |  |  Thanos |          |  Thanos         |
       |  Sidecar A |  |  Store  |          |  Sidecar B      |
       |  (on Pi)   |  |  (on Pi)|          |  (on OCI, WG)   |
       +------+-----+  +----+----+          +-------+---------+
              |             |                       |
       +------v-----+       +---> R2 (long-term)    |
       | Prometheus |                               |
       | replica A  |                               |
       | (on Pi)    |                               |
       +------+-----+                               |
              |                                     |
              +---> R2 (long-term)     +------------v---------+
                                       | Prometheus replica B |
                                       | (on OCI Ampere A1)   |
                                       +----------------------+
                                                   |
                              scrapes homelab targets over WG
                              (10.0.0.1:*) and OCI-local (10.0.0.4:*)
```

## Key config differences from Pi's replica

- `external_labels.replica: 'b'` (Pi's is `'a'`)
- Every target on the Pi is scraped over WireGuard at `10.0.0.1:*`
- A single `relabel_configs` per non-blackbox job rewrites the
  `instance` label from `10.0.0.1:PORT` to `localhost:PORT`, so
  post-dedup series identity matches the Pi replica exactly
- Alertmanager target points to `10.0.0.1:9093` (still on Pi)
- Rule files sync from Pi (identical set on both replicas so alerts
  fire consistently); Alertmanager dedups fingerprints

## Deploy

The Pi has a sync timer that pulls this repo every 5 min. OCI has no
equivalent yet - deploy is manual for now, tracked in the ADR's
follow-ups.

Manual deploy from Mac:

```bash
# scp configs
scp -i ~/.ssh/id_ed25519_oracle \
    system/prometheus-oci/prometheus.yml \
    system/prometheus-oci/prometheus.service \
    system/prometheus-oci/thanos-sidecar.service \
    ubuntu@163.192.1.153:/tmp/

# on OCI
ssh -i ~/.ssh/id_ed25519_oracle ubuntu@163.192.1.153
sudo cp /tmp/prometheus.yml /etc/prometheus/prometheus.yml
sudo cp /tmp/prometheus.service /etc/systemd/system/
sudo cp /tmp/thanos-sidecar.service /etc/systemd/system/
sudo chown prometheus:prometheus /etc/prometheus/prometheus.yml
sudo systemctl daemon-reload
sudo -u prometheus /opt/prometheus/promtool check config /etc/prometheus/prometheus.yml
sudo systemctl reload-or-restart prometheus thanos-sidecar
```

## Rule files and alerts.yml

The rule files under `/etc/prometheus/rules/` on OCI come from the Pi
via one-shot rsync:

```bash
ssh bibigon88@homebridge 'sudo tar -C /etc/prometheus/rules -cf - .' | \
    ssh -i ~/.ssh/id_ed25519_oracle ubuntu@163.192.1.153 \
        'sudo tar -C /etc/prometheus/rules -xf -'
ssh bibigon88@homebridge 'sudo cat /etc/prometheus/alerts.yml' | \
    ssh -i ~/.ssh/id_ed25519_oracle ubuntu@163.192.1.153 \
        'sudo tee /etc/prometheus/alerts.yml >/dev/null'
```

Not automated yet - see follow-ups in the ADR.

## Firewall

Two ports are opened on wg0 for Pi's Thanos Query to reach the OCI
sidecar gRPC and HTTP metrics:

```bash
sudo iptables -I INPUT -i wg0 -p tcp --dport 10901 -j ACCEPT
sudo iptables -I INPUT -i wg0 -p tcp --dport 19191 -j ACCEPT
sudo netfilter-persistent save
```

Rules 9100 (ebpf-observer) and 9102 (traffic-gen) already existed.

## Known gaps

- Rule files are not auto-synced from repo (Pi is; OCI is not)
- No systemd override for graceful shutdown TimeoutStopSec on the
  Thanos sidecar (Prometheus has it)
- Sidecar ships to the same R2 bucket with the same credentials as
  Pi's - separate keys per replica would be cleaner audit
- The `up{job="prometheus"}` counts an extra series for
  OCI-self-scrape (10.0.0.4:9090). Pi does not scrape OCI's Prometheus
  yet; adding it symmetrically would fully close that gap

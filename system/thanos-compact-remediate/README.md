# thanos-compact-remediate

A small systemd bundle that detects the known Thanos `checksum mismatch`
failure modes on the homelab Pi 5 and tells a human about them.

> **Detection only since 2026-11-21.** Earlier versions marked the
> offending block (`no-downsample-mark.json` / `no-compact-mark.json`)
> and restarted the compactor. That silenced the crash loop, but the
> marked range was then never downsampled and was quietly deleted by
> raw retention. October 2026 was lost this way, and five corrupt
> blocks from early November were hidden behind markers nobody knew
> about. See
> [`docs/postmortems/2026-11-21-thanos-silent-block-corruption.md`](../../docs/postmortems/2026-11-21-thanos-silent-block-corruption.md).

Background: [`docs/runbooks/thanos-compact.md`](../../docs/runbooks/thanos-compact.md).

## What it does

Every 2 minutes, a systemd timer runs a bash script that:

1. Checks whether `thanos-compact.service` is in a bad state
   (systemd-failed, `thanos_compact_halted=1`, or the
   `thanos_compact_downsample_failures_total` counter increased since
   the last tick together with a checksum-shaped error in the logs;
   counter bumps without one are treated as transient and skipped).
2. Parses the offending block ULID and stage from
   `journalctl -u thanos-compact`, covering both the Thanos 0.41 and
   0.42+ error wordings (`downsample block <ULID>`, `from block <ULID>`,
   `input block index not valid` + preceding `downloaded block id=`,
   and `gather index issues for block /path/<ULID>`).
3. Decodes the block creation time from the ULID.
4. Posts **one** `ThanosCompactCorruptBlock` alert per (block, stage)
   per 24h to the local telegram-bridge webhook: ULID, stage, creation
   time and age, the raw checksum detail, and the marker that would
   stop the crash loop, together with its cost.
5. Changes nothing. No markers, no restarts, no writes to R2.

If the block cannot be identified, it posts `ThanosCompactNeedsAttention`
(also deduplicated per 24h).

## Files in this bundle

| File | Installed to |
|------|--------------|
| `thanos-compact-auto-remediate` | `/usr/local/bin/thanos-compact-auto-remediate` (0755) |
| `thanos-compact-remediate.service` | `/etc/systemd/system/thanos-compact-remediate.service` |
| `thanos-compact-remediate.timer` | `/etc/systemd/system/thanos-compact-remediate.timer` |

State written by the script at runtime, not tracked by git:

- `/var/lib/thanos-remediate/last_downsample_failures` — last counter value seen
- `/var/lib/thanos-remediate/reported.log` — dedup state (`<unix_ts> <ULID>:<stage>`), entries older than 24h are pruned
- `/var/lib/thanos-remediate/actions.log`, `mark.log` — historical audit trail from the auto-marking era (pre 2026-11-21), no longer written. Keep: it is the only record of which blocks were marked

## Install

Prerequisites on the target host:

- `thanos-compact.service` already running under systemd
- `/etc/thanos/objstore.yml` present and readable by root
- `alertmanager-telegram-bridge` reachable at `http://localhost:30119/webhook`
  (this repo assumes it's exposed as a k3s NodePort service)

Copy the files into place:

```bash
sudo install -m 0755 thanos-compact-auto-remediate \
    /usr/local/bin/thanos-compact-auto-remediate

sudo install -m 0644 thanos-compact-remediate.service \
    /etc/systemd/system/thanos-compact-remediate.service

sudo install -m 0644 thanos-compact-remediate.timer \
    /etc/systemd/system/thanos-compact-remediate.timer

sudo mkdir -p /var/lib/thanos-remediate
sudo chown root:root /var/lib/thanos-remediate
sudo chmod 0755 /var/lib/thanos-remediate

# node_exporter textfile collector must be able to read the metric file.
# Directory usually already exists for other textfile exporters (router,
# speedtest, etc.) - this is just a sanity check.
test -d /var/lib/prometheus/node-exporter || sudo install -d -o prometheus -g prometheus -m 0755 /var/lib/prometheus/node-exporter

sudo systemctl daemon-reload
sudo systemctl enable --now thanos-compact-remediate.timer
```

Verify:

```bash
sudo systemctl list-timers | grep thanos
sudo systemctl start thanos-compact-remediate.service
sudo journalctl -u thanos-compact-remediate.service -n 20 --no-pager
```

When `thanos-compact` is healthy, expected output is a single line
`Deactivated successfully. Finished.` with no Telegram notification.
The script never mutates R2.

## Uninstall

```bash
sudo systemctl disable --now thanos-compact-remediate.timer
sudo rm -f /etc/systemd/system/thanos-compact-remediate.timer
sudo rm -f /etc/systemd/system/thanos-compact-remediate.service
sudo rm -f /usr/local/bin/thanos-compact-auto-remediate
sudo systemctl daemon-reload
# Optional: keep state (actions.log / mark.log are the audit trail of the auto-marking era).
# sudo rm -rf /var/lib/thanos-remediate
```

## Operations

**Recent runs** (every 2 minutes, expect silent success most of the time):

```bash
sudo journalctl -u thanos-compact-remediate.service --since "1 hour ago" --no-pager
```

**What did the old auto-marking version do to my bucket:**

```bash
sudo cat /var/lib/thanos-remediate/actions.log          # <ts> <trigger> <ulid> <marker>
sudo tail -100 /var/lib/thanos-remediate/mark.log       # full thanos tools output
```

**Disable temporarily** (e.g. during manual debugging so it doesn't
race against you):

```bash
sudo systemctl stop thanos-compact-remediate.timer
# ...poke around...
sudo systemctl start thanos-compact-remediate.timer
```

## Alerts emitted

The script POSTs Alertmanager-shaped JSON directly to the local
telegram-bridge webhook. Prometheus only alerts on the detector itself
being stale. (Until 2026-11-21 both paths alerted on the same events,
which produced every notification twice.)

| Alertname | Severity | Source | Runbook anchor | Meaning |
|-----------|----------|--------|----------------|---------|
| `ThanosCompactCorruptBlock` | critical | script | `#corrupt-block` | A block fails compaction/downsample with a checksum error. Nothing was changed; decide per runbook |
| `ThanosCompactNeedsAttention` | critical | script | `#manual-recovery` | Compactor unhealthy but the block could not be identified from logs |
| `ThanosCompactAutoRemediateStale` | warning | Prometheus | `#timer-not-running` | No detector run in 10+ min, timer may be stopped |

## Metrics

Script writes the following to `/var/lib/prometheus/node-exporter/thanos-remediate.prom` on every exit path (atomic tmp+mv). Metric names are kept from the auto-remediation era so existing dashboards keep working:

- `thanos_compact_auto_remediate_total{result="..."}` - cumulative counter. Current values: `not_needed`, `reported`, `already_reported`, `unidentified`, `transient_skipped`. Old values (`succeeded`, `gave_up`, `rate_limited`, `mark_failed`, `service_down`) stay frozen at their last count.
- `thanos_compact_auto_remediate_last_run_timestamp_seconds` - Unix timestamp of last run. Used by `ThanosCompactAutoRemediateStale` to detect a stopped timer.

Per-result counts are kept in `/var/lib/thanos-remediate/result_<name>` files between runs - deleting these resets the counters without affecting operation.

Verify on the Pi:

    cat /var/lib/prometheus/node-exporter/thanos-remediate.prom
    curl -s http://localhost:9100/metrics | grep thanos_compact_auto_remediate

## Design choices worth calling out

- **No Telegram bot token on the Pi filesystem.** The script POSTs
  Alertmanager-shaped JSON to the local `alertmanager-telegram-bridge`
  webhook, reusing the credentials that already live in a Kubernetes
  secret. If the bridge is down, notifications are silently dropped
  — accepted trade-off for a homelab: `ThanosCompactDown` from
  Prometheus still fires through Alertmanager.
- **2-minute polling instead of an event-driven trigger.** Considered
  a `Restart=on-failure`-style path plus a systemd `PathUnit` on
  metrics, but polling is simpler, has no failure modes of its own,
  and 2 minutes of extra downtime doesn't matter for a homelab
  compactor.
- **No automatic markers.** A marker is a data-retention decision, not
  a restart. `no-downsample-mark.json` on a raw block means its range
  never gets 5m/1h resolution and disappears when raw retention
  expires; `no-compact-mark.json` freezes the block at its level. The
  right call depends on block age, whether its sources still exist,
  and whether the corruption is a one-off or a pattern. A script
  cannot see that; a human reading one alert can.
- **Dedup per (block, stage) for 24h.** The compactor crash-loops every
  minute on a bad block; one alert is enough.

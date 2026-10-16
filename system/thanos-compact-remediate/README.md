# thanos-compact-remediate

A small systemd bundle that automatically remediates the known
Thanos-internal `checksum mismatch` failure modes on the homelab Pi 5.

Background: [`docs/runbooks/thanos-compact.md`](../../docs/runbooks/thanos-compact.md)
and [`docs/postmortems/2026-08-05-thanos-compact-checksum-cascade.md`](../../docs/postmortems/2026-08-05-thanos-compact-checksum-cascade.md).

## What it does

Every 2 minutes, a systemd timer runs a bash script that:

1. Checks whether `thanos-compact.service` is in a bad state
   (systemd-failed, or `thanos_compact_halted=1`, or the
   `thanos_compact_downsample_failures_total` counter increased
   since the last tick).
2. If so, parses the offending block ULID from
   `journalctl -u thanos-compact` and picks the correct marker
   based on the stage that failed:
   - `downsample block <ULID>` → `no-downsample-mark.json` (Thanos ≤0.41)
   - `from block <ULID>` → `no-compact-mark.json` (Thanos ≤0.41)
   - `input block index not valid: read series: invalid checksum`
     (Thanos ≥0.42) → block ID is no longer in the error line, so
     the script walks back to the preceding `msg="downloaded block"
     id=<ULID>` line and picks the marker from the stage word in the
     error (`downsampling` / `downsample` → downsample marker,
     otherwise compact marker).
   - `gather index issues for block /path/<ULID>: read series: invalid checksum`
     (Thanos ≥0.42, compact stage on locally-cached blocks) → no
     `downloaded block` line to walk back to. ULID is extracted
     directly from the filesystem path in the error. Marker is always
     `no-compact-mark.json` for this path.

   For the `downsample_fail` trigger (counter-based detection), the
   script additionally checks recent logs for checksum-shaped wording
   before acting. If the counter incremented but no checksum error is
   present (e.g. `context canceled` on a block download), the script
   logs `likely transient; skipping remediation` and exits cleanly -
   Thanos retries these on its own.
3. Marks the block with `thanos tools bucket mark`.
4. Restarts the service. Uses `SIGKILL` for the halted-process case
   because `SIGTERM` hangs indefinitely in that state.
5. Waits 30 seconds and verifies recovery.
6. Posts an Alertmanager-shaped notification to the local
   telegram-bridge webhook (same channel used by Alertmanager itself,
   so no Telegram bot token lives on the Pi filesystem).

Rate-limited to 5 actions per hour to prevent runaway loops from a
future script bug.

## Files in this bundle

| File | Installed to |
|------|--------------|
| `thanos-compact-auto-remediate` | `/usr/local/bin/thanos-compact-auto-remediate` (0755) |
| `thanos-compact-remediate.service` | `/etc/systemd/system/thanos-compact-remediate.service` |
| `thanos-compact-remediate.timer` | `/etc/systemd/system/thanos-compact-remediate.timer` |

State written by the script at runtime, not tracked by git:

- `/var/lib/thanos-remediate/last_downsample_failures` — last counter value seen
- `/var/lib/thanos-remediate/actions.log` — rate-limit tracking (`<unix_ts> <trigger> <ulid> <marker>`)
- `/var/lib/thanos-remediate/mark.log` — full output of every `thanos tools bucket mark` invocation

## Install

Prerequisites on the target host:

- `thanos-compact.service` already running under systemd
- `/etc/thanos/objstore.yml` present and readable by root
- `/usr/local/bin/thanos` binary available (used for `thanos tools bucket mark`)
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
`Deactivated successfully. Finished.` with no Telegram notification
and no mutations to R2.

## Uninstall

```bash
sudo systemctl disable --now thanos-compact-remediate.timer
sudo rm -f /etc/systemd/system/thanos-compact-remediate.timer
sudo rm -f /etc/systemd/system/thanos-compact-remediate.service
sudo rm -f /usr/local/bin/thanos-compact-auto-remediate
sudo systemctl daemon-reload
# Optional: keep state (contains a useful audit log of past marks).
# sudo rm -rf /var/lib/thanos-remediate
```

## Operations

**Recent runs** (every 2 minutes, expect silent success most of the time):

```bash
sudo journalctl -u thanos-compact-remediate.service --since "1 hour ago" --no-pager
```

**What has this thing done to my bucket:**

```bash
sudo tail -100 /var/lib/thanos-remediate/mark.log       # full thanos tools output
sudo cat /var/lib/thanos-remediate/actions.log          # audit trail
```

**Disable temporarily** (e.g. during manual debugging so it doesn't
race against you):

```bash
sudo systemctl stop thanos-compact-remediate.timer
# ...poke around...
sudo systemctl start thanos-compact-remediate.timer
```

## Alerts emitted

Two parallel notification paths, during migration period:

**Path A - direct webhook from script** (legacy, kept as fallback if Prometheus itself is down). The script POSTs Alertmanager-shaped JSON directly to the local telegram-bridge webhook. No `generatorURL` in these alerts.

**Path B - Prometheus textfile metric** (new, preferred). Script writes `thanos_compact_auto_remediate_total{result="..."}` to a node_exporter textfile. Prometheus scrapes it, alertmanager rules fire on the counter, bridge delivers to Telegram as usual. These alerts carry `generatorURL` and `runbook_url` annotations.

Direct-webhook (Path A) will be removed in a future PR after 2-4 weeks of Path B validation.

| Alertname | Severity | Path | Runbook anchor | Meaning |
|-----------|----------|------|----------------|---------|
| `ThanosCompactAutoRemediated` | info | A | `#auto-remediation` | Remediation ran, service is healthy again |
| `ThanosCompactAutoRemediated` | critical | A | `#auto-remediation` | Remediation ran but service did not come back up in 30s |
| `ThanosAutoRemediateRateLimit` | critical | A | `#alert-thanosautoremediateratelimit` | Script hit per-hour rate limit, gave up |
| `ThanosAutoRemediateGaveUp` | critical | A | `#alert-thanosautoremediategaveup` | Cannot identify offending block/stage from logs |
| `ThanosAutoRemediateFailed` | critical | A | `#alert-thanosautoremediatefailed` | `thanos tools bucket mark` call failed |
| `ThanosCompactAutoRemediateGaveUp` | critical | B | `#alert-thanosautoremediategaveup` | Counter `result="gave_up"` incremented |
| `ThanosCompactAutoRemediateRateLimit` | critical | B | `#alert-thanosautoremediateratelimit` | Counter `result="rate_limited"` incremented |
| `ThanosCompactAutoRemediateMarkFailed` | critical | B | `#alert-thanosautoremediatefailed` | Counter `result="mark_failed"` incremented |
| `ThanosCompactAutoRemediateStale` | warning | B | `#timer-not-running` | No run in 10+ min, timer may be stopped |

## Metrics

Script writes the following to `/var/lib/prometheus/node-exporter/thanos-remediate.prom` on every exit path (atomic tmp+mv):

- `thanos_compact_auto_remediate_total{result="..."}` - cumulative counter. Values: `not_needed`, `succeeded`, `gave_up`, `rate_limited`, `mark_failed`, `service_down`, `transient_skipped`.
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
  and the remediation still proceeds — this is intentional. The
  goal is to fix the service, not to guarantee a notification.
- **2-minute polling instead of an event-driven trigger.** Considered
  a `Restart=on-failure`-style path plus a systemd `PathUnit` on
  metrics, but polling is simpler, has no failure modes of its own,
  and 2 minutes of extra downtime doesn't matter for a homelab
  compactor.
- **Rate limiting on wall time, not counter.** 5 actions in the last
  hour, not "5 actions ever." This is because the failure pattern
  is one bad block per few weeks, not one every few minutes — if we
  are triggering more than 5 in an hour something else is going on
  (script bug, upstream regression, actual R2 outage) and the loop
  needs a human.
- **Distinct markers by stage.** `no-downsample-mark.json` and
  `no-compact-mark.json` are functionally different — the first only
  suppresses downsample of a given block, the second suppresses
  compaction. Using the wrong one just means the compactor will
  hit the same failure again on the next iteration. This is why
  the script differentiates.

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
   - `downsample block <ULID>` → `no-downsample-mark.json`
   - `from block <ULID>` → `no-compact-mark.json`
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

| Alertname | Severity | Meaning |
|-----------|----------|---------|
| `ThanosCompactAutoRemediated` | info | Remediation ran, service is healthy again |
| `ThanosCompactAutoRemediated` | critical | Remediation ran but service did not come back up in 30s |
| `ThanosAutoRemediateRateLimit` | critical | 5+ actions in the last hour, script gave up to avoid a runaway loop |
| `ThanosAutoRemediateGaveUp` | critical | Cannot identify the offending block/stage from logs — manual investigation needed |
| `ThanosAutoRemediateFailed` | critical | `thanos tools bucket mark` itself failed — check `mark.log` |

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

# Thanos Compact Runbook

Operational reference for the `thanos-compact.service` running on `homebridge`
(Raspberry Pi 5) against Cloudflare R2 bucket `homelab-thanos`.

Covers three known failure modes, the auto-remediation system that handles
them, and the manual fallback procedure.

---

## TL;DR

If `thanos-compact` is broken and you just want it fixed:

1. Look at the most recent `ThanosCompact*` alert in Telegram to identify the
   failure mode.
2. In most cases, the `thanos-compact-remediate` timer will handle it within
   ~2 minutes. Check for a `ThanosCompactAutoRemediated` alert.
3. If auto-remediate gave up (see `ThanosAutoRemediateGaveUp` /
   `RateLimit` / `Failed` alerts), follow the manual recovery in
   [Manual recovery](#manual-recovery).

---

## Context

- `thanos-compact` runs bare-metal under systemd on the Pi 5, not in k3s.
  It has no HA sibling; when it is down, no compaction and no downsampling
  happens until it recovers.
- Object store is Cloudflare R2; config at `/etc/thanos/objstore.yml`.
- Local state (working dir) is `/var/lib/thanos/compact/`. Discardable —
  Thanos cleans partial uploads on boot.
- Retention: raw 15d, 5m 60d, 1h 90d.
- HTTP `/metrics` is on `:19194`. Prometheus scrapes locally.

---

## Failure modes

There are three distinct symptoms. Same-shaped `checksum mismatch` errors
can produce two of them; the third is a downstream effect.

### 1. `ThanosCompactFailed` — systemd killed the unit

- **Alert severity:** CRITICAL
- **How you see it:** systemd unit is `failed`. `systemctl status
  thanos-compact` shows `Result=exit-code`, `NRestarts=6`,
  `Start request repeated too quickly`. Nothing on `:19194`.
- **What happened:** The compactor hit an unrecoverable error during
  **downsample** (typically `checksum mismatch expected:X actual:Y` where
  both X and Y are non-zero), crashed, systemd restarted it, it crashed
  again on the same block, and after 5 restarts inside `StartLimitBurst`
  systemd gave up.
- **Grep this to identify the bad block:**
  ```bash
  sudo journalctl -u thanos-compact --since "2 hours ago" --no-pager \
      | grep -oE "downsample block [0-9A-Z]{26}" | tail -1
  ```
- **Correct marker:** `no-downsample-mark.json`.
- **Root cause:** long-standing Thanos downsample read-path bug — see
  [Why this keeps happening](#why-this-keeps-happening).

### 2. `ThanosCompactHalted` — process alive, internally stopped

- **Alert severity:** CRITICAL
- **How you see it:** systemd unit is `active (running)`, `/metrics`
  responds, `thanos_compact_halted=1`. No compaction or downsample runs;
  no new blocks land in R2.
- **What happened:** The compactor hit an unrecoverable error during
  **compaction** (typically `cannot populate chunk N from block ULID:
  checksum mismatch expected:0, actual:X` — note `expected:0`, which
  suggests the chunk was uploaded by sidecar without a valid CRC header).
  Thanos does not crash on this — it sets `halted=1` and idles.
- **Grep this to identify the bad block:**
  ```bash
  sudo journalctl -u thanos-compact --since "2 hours ago" --no-pager \
      | grep -oE "from block [0-9A-Z]{26}" | tail -1
  ```
- **Correct marker:** `no-compact-mark.json`.
- **Warning:** `systemctl restart` on a halted process hangs in
  `deactivating (stop-sigterm)` for several minutes because SIGTERM
  handling in halted state is broken. Use
  `systemctl kill --signal=SIGKILL thanos-compact` instead.

### 3. `ThanosCompactDown` — scrape target unreachable

- **Alert severity:** WARNING
- **How you see it:** Prometheus can't scrape `localhost:19194` for over
  10 minutes.
- **What happened:** This is a **downstream signal**, not a root cause.
  If `thanos-compact.service` is failed (mode 1), the port is dead.
  If the box is offline, same thing.
- **Do not treat this alert as the primary signal.** Look for
  `ThanosCompactFailed` or `ThanosCompactHalted` first.

---

## Why this keeps happening

These `checksum mismatch` failures are **not** local corruption. Verified
across three separate incidents:

- R2 returns byte-identical objects across repeated reads
  (`mc cp` twice + `sha256sum` matches).
- `thanos tools bucket verify -i index_known_issues --id=<ULID>` reports
  the block clean.
- No dmesg/EDAC/segfault/OOM/thermal events.
- Peak memory during the crash was ~735MB out of 8GB — no pressure.
- Failure is deterministic per block — same offset, same expected vs
  actual bytes, every time.

This matches a long-known Thanos bug across `thanos-io/thanos`
issues #5944, #6194, #5917, #8611 spanning 2020–2025, reported on
x86 MinIO, S3, Ceph, and Azure Blob. Not arm64-specific. The Thanos
downsample read path (and, less commonly, the compact populate path)
miscalculates chunk CRCs under still-unidentified conditions on
otherwise-valid blocks.

The community remediation — and the reason the `no-downsample-mark.json`
marker exists at all — is to mark the block as "skip this specific step"
and move on. Data at the affected time range remains queryable at raw
resolution; only the downsampled (5m/1h) view is missing.

**No upstream fix is available. Do not expect an upgrade to resolve this.**

At the current load the pattern repeats roughly 1–2 times per month.

---

## Auto-remediation

The `thanos-compact-remediate` systemd timer runs a bash script every
2 minutes to detect and fix all three failure modes automatically.

### Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/thanos-compact-auto-remediate` | The remediation script |
| `/etc/systemd/system/thanos-compact-remediate.service` | Oneshot unit |
| `/etc/systemd/system/thanos-compact-remediate.timer` | 2-minute interval |
| `/var/lib/thanos-remediate/last_downsample_failures` | Last observed counter |
| `/var/lib/thanos-remediate/actions.log` | Rate-limit tracking |
| `/var/lib/thanos-remediate/mark.log` | Full output of `thanos tools bucket mark` calls |

### Trigger logic

Each tick:

1. If `systemctl is-failed thanos-compact` — trigger `failed`.
2. Else if `thanos_compact_halted == 1` — trigger `halted`.
3. Else if `thanos_compact_downsample_failures_total` (summed across
   resolutions) is higher than the value from the previous tick —
   trigger `downsample_fail`.
4. Otherwise — no-op, exit 0.

### Remediation logic

When triggered:

1. Rate limit: if 5+ actions were taken in the last hour, alert and
   give up. Prevents runaway loops from a broken script.
2. Parse block ULID and stage from `journalctl -u thanos-compact
   --since "1 hour ago"`:
   - `"downsample block <ULID>"` → mark as `no-downsample-mark.json`
   - `"from block <ULID>"` → mark as `no-compact-mark.json`
3. Run `thanos tools bucket mark` with the correct marker and a
   `details` string that captures the observed `expected:X actual:Y`
   for future forensics.
4. Restart the service:
   - For `failed`: `systemctl reset-failed` + `start`
   - For `halted` / `downsample_fail`: `SIGKILL` + `start`
     (SIGTERM hangs on halted process)
5. Wait 30 seconds. Verify `is-active` and `halted=0`.
6. POST an `ThanosCompactAutoRemediated` alert with the trigger,
   block ID, marker used, and final service status to the
   `alertmanager-telegram-bridge` (k3s `apps/bridge`, NodePort 30119).

### Notifications

The script does not talk to Telegram directly. It POSTs
Alertmanager-shaped JSON to the local webhook of the same bridge that
Alertmanager itself uses. Bot token stays in the k3s secret, not on
the Pi filesystem.

Alerts the script can emit:

| Alertname | Severity | Meaning |
|-----------|----------|---------|
| `ThanosCompactAutoRemediated` | info | Successful remediation |
| `ThanosCompactAutoRemediated` | critical | Service didn't come back up |
| `ThanosAutoRemediateRateLimit` | critical | 5+ actions in last hour, giving up |
| `ThanosAutoRemediateGaveUp` | critical | Could not identify block/stage from logs |
| `ThanosAutoRemediateFailed` | critical | `thanos tools bucket mark` failed |

### Operations

**Status:**

```bash
sudo systemctl status thanos-compact-remediate.timer
sudo systemctl list-timers | grep thanos
```

**Recent runs:**

```bash
sudo journalctl -u thanos-compact-remediate.service --since "1 hour ago" --no-pager
```

**Manual run (for testing):**

```bash
sudo systemctl start thanos-compact-remediate.service
sudo journalctl -u thanos-compact-remediate.service -n 30 --no-pager
```

**Disable temporarily** (e.g. during manual debugging):

```bash
sudo systemctl stop thanos-compact-remediate.timer
# ...do stuff...
sudo systemctl start thanos-compact-remediate.timer
```

**See what has been marked and why:**

```bash
sudo tail -100 /var/lib/thanos-remediate/mark.log
sudo cat /var/lib/thanos-remediate/actions.log
```

`actions.log` format: `<unix_ts> <trigger> <block_ulid> <marker>`.

---

## Manual recovery

Use this if auto-remediate gave up, is disabled, or when investigating
a new failure signature that the script doesn't recognize.

### 1. Identify the failure mode

```bash
systemctl is-failed thanos-compact && echo "MODE: failed"
curl -s http://localhost:19194/metrics 2>/dev/null \
    | grep -E "^thanos_compact_halted " \
    && echo "MODE: check halted=1"
```

### 2. Find the bad block

```bash
sudo journalctl -u thanos-compact --since "2 hours ago" --no-pager \
    | grep -iE "critical error|halting|checksum|out.of.order" | tail -5
```

Extract the ULID from either `downsample block <ULID>` (mode 1) or
`from block <ULID>` (mode 2).

### 3. Confirm the block is actually intact (optional but educational)

```bash
sudo thanos tools bucket verify \
    --objstore.config-file=/etc/thanos/objstore.yml \
    --id=<ULID> \
    -i index_known_issues
```

Expect: `verify task completed`, no errors. This confirms the block
itself is fine and the bug is in Thanos's read path.

### 4. Mark the block

Choose the marker by stage:

- Downsample failure → `no-downsample-mark.json`
- Compact-populate failure → `no-compact-mark.json`

```bash
sudo thanos tools bucket mark \
    --id=<ULID> \
    --objstore.config-file=/etc/thanos/objstore.yml \
    --marker=<MARKER_FILENAME> \
    --details="manual remediation $(date -u +%FT%TZ): <observed expected/actual>"
```

### 5. Restart

For `failed` mode:

```bash
sudo systemctl reset-failed thanos-compact
sudo systemctl start thanos-compact
```

For `halted` mode — do not use `restart`, it will hang for minutes:

```bash
sudo systemctl kill --signal=SIGKILL thanos-compact
sleep 3
sudo systemctl reset-failed thanos-compact 2>/dev/null || true
sudo systemctl start thanos-compact
```

### 6. Verify recovery

```bash
sleep 30
sudo systemctl status thanos-compact --no-pager | head -5
curl -s http://localhost:19194/metrics | grep -E "^thanos_compact_halted "
sudo journalctl -u thanos-compact --since "1 min ago" --no-pager | tail -20
```

Expect: `active (running)`, `thanos_compact_halted 0`, logs showing
`start of compactions` and `compaction iterations done`.

---

## Backlog

- Add a Grafana panel replacing "Compactor Halted" (which reads a stale
  metric when the service is down and misleadingly shows "Healthy")
  with `up{job="thanos-compact"}`.
- Consider filing a fresh reproduction into upstream issue #8611 with
  the sha256-stable-across-reads + verify-clean evidence gathered here.
- Explore whether the compact-stage `expected:0` variant (mode 2) is
  worth a separate upstream issue against sidecar rather than compactor.

# Thanos Compact Runbook

Operational reference for the `thanos-compact.service` running on `homebridge`
(Raspberry Pi 5) against Cloudflare R2 bucket `homelab-thanos`.

Covers three known failure modes, the corruption detector that reports
them, and the manual recovery procedure.

---

## TL;DR

If `thanos-compact` is broken:

1. Look for a `ThanosCompactCorruptBlock` alert in Telegram. It names the
   block ULID, the failing stage, the block age and the checksum detail.
   Nothing has been changed automatically.
2. Follow [Manual recovery](#manual-recovery). Step 0 is a decision, not
   a command: a marker is a data-retention decision.
3. A cluster of corrupt blocks in a short window is a host problem, not a
   Thanos bug. See [Why this keeps happening](#why-this-keeps-happening).

---

## Context

- `thanos-compact` runs bare-metal under systemd on the Pi 5, not in k3s.
  It has no HA sibling; when it is down, no compaction and no downsampling
  happens until it recovers.
- Object store is Cloudflare R2; config at `/etc/thanos/objstore.yml`.
- Local state (working dir) is `/var/lib/thanos/compact/`. Discardable —
  Thanos cleans partial uploads on boot.
- Retention: raw 30d, 5m 60d, 1h 90d (raw was 15d until 2026-11-21; it
  left too little margin for downsampling when compaction stalls).
- No `--deduplication.replica-label` (removed 2026-11-21). Only replica
  `a` (the Pi) uploads to R2; the OCI replica `b` sidecar serves live
  queries only.
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

> **Correction 2026-11-21.** The analysis below (kept for history) concluded
> these were an upstream Thanos read-path bug on otherwise-valid blocks.
> That was wrong, or at best incomplete. On 2026-11-19..21 every raw block
> written in early November failed downsample deterministically, a fresh
> compactor output contained ASCII text (`.com`) where a chunk CRC should
> be, and an unrelated Python CronJob on the same host read NUL bytes from
> a library file that is intact on disk. The common factor is the Pi 5
> host (memory path), not Thanos. The bootloader EEPROM (SDRAM init) was
> six months out of date and was updated on 2026-11-21. See
> [`docs/postmortems/2026-11-21-thanos-silent-block-corruption.md`](../postmortems/2026-11-21-thanos-silent-block-corruption.md).
>
> Practical consequence: treat a checksum error as "this block is really
> corrupt", and treat several in a short window as a host incident.

### Original analysis (superseded)

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

## Corruption detector

The `thanos-compact-remediate` systemd timer runs
`/usr/local/bin/thanos-compact-auto-remediate` every 2 minutes. Since
2026-11-21 it is **detection only**: it never marks blocks, never
restarts the service and never writes to R2. Names are kept from the
auto-remediation era so installs and dashboards keep working.

Triggers: unit `failed`, `thanos_compact_halted == 1`, or
`thanos_compact_downsample_failures_total` increased together with a
checksum-shaped error in recent logs.

On trigger it parses the block ULID and stage from `journalctl` (all
Thanos 0.41 and 0.42+ wordings, see the bundle README), decodes the
block creation time from the ULID and posts one `ThanosCompactCorruptBlock`
alert per (block, stage) per 24h. Dedup state lives in
`/var/lib/thanos-remediate/reported.log`.

Why it no longer marks: a marker silenced the crash loop and the alert,
but `no-downsample-mark.json` on a raw block means the range never gets
5m/1h and is deleted by raw retention. That is how October 2026 was lost,
and how five corrupt November blocks sat unnoticed behind markers.

**Audit trail of the old behaviour** (only record of what was marked):

```bash
sudo cat /var/lib/thanos-remediate/actions.log   # <ts> <trigger> <ulid> <marker>
sudo tail -100 /var/lib/thanos-remediate/mark.log
```

**Operations:**

```bash
sudo systemctl list-timers | grep thanos-compact-remediate
sudo journalctl -u thanos-compact-remediate.service --since "1 hour ago" --no-pager
sudo systemctl start thanos-compact-remediate.service   # manual run
```

---

## Manual recovery

### 0. Decide before you mark

A checksum error means the block is corrupt. Options, best first:

1. **Sources still exist** (block younger than `--delete-delay`, 48h, and
   compact stopped so the cleaner has not run): delete the corrupt output
   (`--marker=deletion-mark.json`), remove `deletion-mark.json` from its
   sources (`--remove`), and let the compactor rebuild it. To avoid an
   overlap halt from the 24h deletion-mark filter delay, purge right away
   with `thanos tools bucket cleanup --delete-delay=0s` (irreversible for
   everything currently marked).
2. **Range is duplicated elsewhere** (another lineage covers it): mark the
   corrupt block for deletion.
3. **Only copy:** mark it (`no-downsample` / `no-compact`). Raw stays
   queryable apart from the corrupt series, but the range gets no 5m/1h
   and disappears when raw retention expires. Note the date.

If several blocks fail within hours, stop `thanos-compact` first: the
compactor may be writing new corrupt blocks and marking good sources for
deletion as it goes.

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

Expect: `verify task completed`, no errors. This only checks the index;
it does not read chunks, so a clean result does not prove the block is
intact (all five corrupt November blocks were verify-clean).

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

---

## Alert to section mapping

Each alert's `runbook_url` annotation points to one of these anchors.

| Alert | Section |
|-------|---------|
| `ThanosCompactHalted` | [`#alert-thanoscompacthalted`](#alert-thanoscompacthalted) |
| `ThanosCompactFailed` | [`#alert-thanoscompactfailed`](#alert-thanoscompactfailed) |
| `ThanosCompactDown` | [`#alert-thanoscompactdown`](#alert-thanoscompactdown) |
| `ThanosCompactCorruptBlock` | [`#corrupt-block`](#corrupt-block) |
| `ThanosCompactNeedsAttention` | [`#manual-recovery`](#manual-recovery) |
| `ThanosCompactAutoRemediateStale` | [`#timer-not-running`](#timer-not-running) |

---

## Fallback 4: compact-stage filesystem path (Thanos 0.42+)

Added 2026-10-14 after recurrence #6 - see postmortem.

In Thanos 0.42+, compact-stage errors on blocks the compactor read from local disk (not freshly downloaded from R2) do not emit any of the three error wordings fallbacks 1-3 search for, nor a preceding `msg="downloaded block" id=<ULID>` line to walk back to. The block ULID appears only inside the filesystem path within the error itself:

    gather index issues for block /var/lib/thanos/compact/compact/0@<GROUP>/<ULID>: read series: invalid checksum

Fallback 4 extracts the ULID from this path (pattern `block /[^ ]+/[0-9A-Z]{26}:`). Marker is always `no-compact-mark.json` for this path - compact-stage errors never contain the word "downsample" in this wording.

To debug when a new wording appears and all 4 fallbacks fail:

    sudo journalctl -u thanos-compact --since "2 hours ago" --no-pager \
        | grep -E "level=error|invalid checksum|downloaded block|downsample" | tail -30

Then look for `[0-9A-Z]{26}` anywhere in the output to find the ULID, and determine the stage from the surrounding wording. File a follow-up PR adding a 5th fallback.

---

## Transient downsample_fail guard

Added 2026-10-15 after recurrence #7.

The `downsample_fail` trigger (incremented counter `thanos_compact_downsample_failures_total`) fires on any single-tick increment, including transient errors like `context canceled`, timeouts, or R2 connection failures that Thanos retries on its own. These false-positives surfaced as `ThanosAutoRemediateGaveUp` because the script had no checksum-shaped log line to parse a ULID from.

The guard checks recent logs for `checksum|invalid|corrupt|gather index` before triggering. If none appear, the script logs `likely transient; skipping remediation`, writes `transient_skipped` to the counter, and exits cleanly.

To check how often this fires:

    cat /var/lib/thanos-remediate/result_transient_skipped
    curl -s http://localhost:9100/metrics | grep 'thanos_compact_auto_remediate_total{result="transient_skipped"}'

If this grows rapidly, something is causing frequent download failures (R2 outage, network issue, DNS). Investigate separately - the guard just prevents false alerts, it does not fix the underlying flakiness.

---

## Timer not running

Alert `ThanosCompactAutoRemediateStale` fires when `thanos_compact_auto_remediate_last_run_timestamp_seconds` is older than 10 minutes (expected run interval is 2 min).

Possible causes:

1. `thanos-compact-remediate.timer` is stopped or disabled.
2. The script runs but cannot write to `/var/lib/prometheus/node-exporter/thanos-remediate.prom` (permission issue after a package update).
3. `node_exporter` textfile collector is not reading the directory, or exporter itself is down.

Diagnose:

    sudo systemctl status thanos-compact-remediate.timer
    sudo systemctl list-timers | grep thanos-compact-remediate
    ls -la /var/lib/prometheus/node-exporter/thanos-remediate.prom
    sudo journalctl -u thanos-compact-remediate.service --since "30 min ago" --no-pager | tail -40
    curl -s http://localhost:9100/metrics | grep thanos_compact_auto_remediate_last_run

Fix for case 1:

    sudo systemctl enable --now thanos-compact-remediate.timer

---

## Alert anchors (for runbook_url)

Each `<a id="...">` anchor below is referenced by a Prometheus alert's `runbook_url` annotation. Keep them in sync with `prometheus/rules/thanos-alerts.yml`.

<a id="alert-thanoscompacthalted"></a>
### alert-thanoscompacthalted

See [Failure mode 2](#2-thanoscompacthalted--process-alive-internally-stopped) above and [Manual recovery](#manual-recovery) for the halted-process restart sequence (SIGKILL, not SIGTERM).

<a id="alert-thanoscompactfailed"></a>
### alert-thanoscompactfailed

See [Failure mode 1](#1-thanoscompactfailed--systemd-killed-the-unit) above and [Manual recovery](#manual-recovery).

<a id="alert-thanoscompactdown"></a>
### alert-thanoscompactdown

Downstream signal, not root cause. First check if `ThanosCompactFailed` or `ThanosCompactHalted` is also firing - see [Failure mode 3](#3-thanoscompactdown--scrape-target-unreachable).

<a id="corrupt-block"></a>
### corrupt-block (ThanosCompactCorruptBlock)

A specific block fails compaction or downsample with a checksum error.
Nothing was changed automatically. Go to [Manual recovery](#manual-recovery),
step 0. One alert per (block, stage) per 24h; more than one block in a
day points at the host, not at Thanos.

<a id="alert-thanosautoremediategaveup"></a>
<a id="alert-thanosautoremediateratelimit"></a>
<a id="alert-thanosautoremediatefailed"></a>
<a id="auto-remediation"></a>
### Legacy auto-remediation alerts

`ThanosAutoRemediateGaveUp`, `ThanosAutoRemediateRateLimit`,
`ThanosAutoRemediateFailed`, `ThanosCompactAutoRemediated` and their
`ThanosCompactAutoRemediate*` Prometheus twins were retired on
2026-11-21 together with automatic marking. Anchors are kept so old
Telegram messages still resolve.

<a id="timer-not-running"></a>
### timer-not-running

See [Timer not running](#timer-not-running-1) section above.

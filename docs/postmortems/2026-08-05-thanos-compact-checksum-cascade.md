# Postmortem: Thanos Compact checksum cascade

- **Date:** 2026-08-04 to 2026-08-05
- **Duration:** ~10 hours of degraded compaction/downsampling across three
  separate incidents; ingestion and query paths unaffected throughout
- **Impact:** Downsampled (5m/1h) rollups for the 03–05 Aug UTC time
  window are permanently unavailable. Raw resolution for the same
  window is intact and queryable. No lost samples, no user-facing
  outage
- **Detection:** Alertmanager → Telegram (`ThanosCompactFailed`,
  `ThanosCompactHalted`, `ThanosCompactDown`)
- **Response:** Manual on both August 4 (overnight) and mid-day
  August 5. Auto-remediation was written and deployed the same
  afternoon to prevent future toil
- **Blameless framing:** the underlying failure is an upstream Thanos
  bug affecting many operators across multiple object stores. This
  writeup focuses on what we learned about the failure surface and
  how the response can be improved next time, not on individual
  actions

---

## Summary

Over roughly 16 hours, `thanos-compact` on the homelab Pi 5 hit
three distinct incidents driven by two related but different
Thanos-internal `checksum mismatch` failure modes:

1. **22:32 PDT Aug 4** — `ThanosCompactFailed`. A level-3 compactor-
   generated block failed downsample with a non-zero `expected` vs
   non-zero `actual` CRC mismatch. The compactor crashed, systemd
   restarted it, it crashed on the same block, and after five
   restarts inside 600 seconds systemd hit `StartLimitBurst` and
   gave up.
2. **05:12–07:22 Aug 5** — Alert fatigue. The initial `Failed`
   alert re-fired every ~65 minutes via `repeat_interval` while the
   operator was asleep. Investigation began at ~08:00 PDT.
3. **14:38 PDT Aug 5** — `ThanosCompactHalted`. Immediately after
   the operator returned from an off-site event, a fresh level-1
   sidecar-uploaded block failed compaction with `expected:0,
   actual:X`. The process did not crash — it set
   `thanos_compact_halted=1` and idled while systemd continued to
   see it as `active (running)`.

Both incidents were resolved by marking the offending block with a
per-stage marker (`no-downsample-mark.json` and `no-compact-mark.json`
respectively) and restarting the service. An automated remediation
was designed, implemented, and deployed to systemd by 16:30 PDT the
same day.

---

## Timeline (all times PDT)

### 2026-08-04

- **22:31:03** — Sidecar/compactor complete a routine level-2 upload.
- **22:32:04–08** — Compactor writes a new level-3 block
  `01KZ86FAR5YQNC8BS17SV7MBEQ` to R2 (2 chunks + index + meta,
  finalized cleanly).
- **22:32:43** — 35 seconds after finalization, the compactor
  attempts to downsample the block it just wrote, and fails with
  `chunk 465944493, series 1093172: checksum mismatch
  expected:791973a8, actual:dad41f95`.
- **22:32:43–22:40:14** — systemd restarts the unit five times.
  Each PID lives ~90 seconds: start → sync bucket → begin downsample
  → crash on the same chunk.
- **22:41:14** — systemd logs `Start request repeated too quickly.`
  Unit enters `failed` state with `Result=exit-code`,
  `NRestarts=6`. Alertmanager fires `ThanosCompactFailed`
  [CRITICAL] at 22:42.

### 2026-08-05

- **05:12, 06:17, 07:22 AM** — `ThanosCompactFailed` re-fires every
  ~65 min via `repeat_interval`. Same underlying incident.
- **07:56 AM** — `ThanosCompactDown` [WARNING] fires: Prometheus
  has been unable to scrape `localhost:19194` for 10 minutes (a
  downstream symptom of the failed unit).
- **~08:00 AM** — Operator wakes and begins investigation.
- **08:23 AM** — Remediation applied: `thanos tools bucket mark
  --marker=no-downsample-mark.json` + `systemctl reset-failed
  thanos-compact` + `systemctl start`. Compactor comes back healthy;
  downsample iterations complete in 1.1s.
- **08:23–14:38** — Investigation continues. Bucket-wide inventory,
  R2 stability check (double-download + sha256 comparison),
  `thanos tools bucket verify` on the affected block, upstream
  issue tracker search. Root cause narrowed to a known
  Thanos-internal bug (see [Root cause](#root-cause)).
- **14:38 PM** — Second incident. `ThanosCompactHalted` [CRITICAL]
  fires. Block `01KZ9DW8ZQRS8GYRDC7GSWSA5A` (level 1, fresh sidecar
  upload) fails compact-populate with `cannot populate chunk
  4489051: checksum mismatch expected:0, actual:10a1765`. The
  compactor sets `thanos_compact_halted=1` and idles; systemd sees
  it healthy.
- **14:47 PM** — `thanos tools bucket mark
  --marker=no-compact-mark.json` runs successfully.
- **14:47–14:52 PM** — `systemctl restart` hangs in
  `deactivating (stop-sigterm)` for 5+ minutes. Workaround:
  `systemctl kill --signal=SIGKILL`. Unit comes back up and
  resumes normal operation.
- **16:30 PM** — Auto-remediation script + systemd
  service/timer deployed. Verified running by 16:33.

---

## Root cause

The `checksum mismatch` errors are **not** local corruption. Multiple
independent checks confirm this:

- **R2 is byte-stable.** `mc cp` of the same chunk twice yields
  identical sha256 sums. R2 returns the same bytes on every read.
- **The block is intact.** `thanos tools bucket verify -i
  index_known_issues --id=<ULID>` reports `verified issue`, zero
  errors.
- **No hardware anomalies.** dmesg has no ECC, memory, segfault,
  thermal, or throttle events across the incident windows.
  `vcgencmd get_throttled` = `0x0` since boot.
- **No resource pressure.** Peak memory during the crash was
  735 MB out of 8 GB. No OOM events. No swap-driven latency.
- **Failure is deterministic per block.** Same offset, same
  `expected` and `actual` bytes, on every retry. This is not
  random data corruption; it is repeatable misinterpretation.

Cross-referencing upstream issues:

- [thanos-io/thanos#5944](https://github.com/thanos-io/thanos/issues/5944)
  (2022) — the request that introduced `no-downsample-mark.json`
  as a mitigation, filed against exactly this failure.
- [thanos-io/thanos#6194](https://github.com/thanos-io/thanos/issues/6194)
  (2023) — identical log signature, x86, S3.
- [thanos-io/thanos#5917](https://github.com/thanos-io/thanos/issues/5917)
  (2022) — "six times in the last eight weeks, each time on a
  different block."
- [thanos-io/thanos#8611](https://github.com/thanos-io/thanos/issues/8611)
  (2025) — most recent report. User on Thanos v0.38, MinIO on
  k8s, x86. Ran `thanos tools bucket verify` (clean), ran
  `promtool tsdb analyze` (clean), downloaded the block locally
  (readable). Concluded the blocks are not corrupt and something
  else is going on. No fix has been merged.

The failure is a Thanos internal read-path issue that miscalculates
CRCs under still-unidentified conditions on otherwise-valid blocks.
It is not arm64-specific, not R2-specific, not resource-driven.

Two distinct manifestations exist:

- **Downsample stage** (mode 1 in the runbook): non-zero
  `expected` and non-zero `actual`. Compactor crashes hard on
  this and enters systemd restart loop.
- **Compact-populate stage** (mode 2): `expected:0` and non-zero
  `actual`. Compactor does not crash; it sets
  `thanos_compact_halted=1` and idles. The zero on the expected
  side suggests the chunk header did not have a valid CRC when
  the compactor started reading it — possibly a sidecar upload
  race, though this is not confirmed.

---

## What went well

- **Alerts fired correctly and quickly.** `ThanosCompactFailed`
  was in Telegram within ~10 minutes of the systemd
  `StartLimitBurst`. `ThanosCompactHalted` fired within a few
  minutes of the halt for the second incident.
- **Log messages contained the exact information needed.** ULID,
  chunk number, series number, and both CRCs were in the
  systemd journal. No log-diving through unrelated services.
- **Impact was cleanly bounded.** Ingestion via sidecar and
  querying via store/query did not experience any outage. Only
  compaction and downsampling stopped.
- **The remediation is reversible and low-risk.** Marking a block
  with `no-downsample-mark.json` costs one downsample rollup for
  that time window; raw data remains queryable.
- **Automation was written the same day, before the situation
  became routine toil.** By the end of the day, the failure
  surface was documented, the remediation was scripted, and the
  script was live on the Pi.

## What went poorly

- **`Compactor Halted` Grafana panel was misleading.** When the
  service was in `failed` state, the panel read a stale
  `thanos_compact_halted=0` and displayed "Healthy." A stat
  panel on `up{job="thanos-compact"}` or a
  `time() - process_start_time_seconds{...}` gauge would have
  conveyed the truth. This is now on the runbook backlog.
- **`repeat_interval: 1h` produced noise, not signal, during the
  overnight window.** Three re-fires between 05:12 and 07:22 for
  the same incident added no information; only the first one
  mattered. `resolve_timeout` and `repeat_interval` are worth
  revisiting for CRITICAL alerts specifically.
- **`systemctl restart` for a halted process hangs.** Discovered
  the hard way during the 14:47 incident. SIGTERM handling in
  the halted state is broken; SIGKILL is required.
  This is now called out in the runbook.
- **The initial hypothesis ("arm64-specific compactor bug")
  turned out to be wrong.** It was a reasonable inference from
  the stack trace showing `asm_arm64.s`, but the upstream issue
  history shows the bug hits x86 on multiple object stores.
  Faster upstream-issue search early in the investigation
  would have saved time.

## What we got lucky on

- The bug hits ~1–2 blocks per month at current load. Higher
  cardinality or a larger retention window would trigger it more
  often and the operational cost would have caught up sooner.
- Both incidents happened during a day the operator was already
  online. Overnight, no-one is watching the `Halted` state,
  which does not crash — data would just silently stop
  compacting.

---

## Action items

- [x] Deploy `thanos-compact-remediate` systemd timer + auto-remediate
  script covering all three failure modes. See
  [`system/thanos-compact-remediate/`](../../system/thanos-compact-remediate/).
- [x] Write operational runbook. See
  [`docs/runbooks/thanos-compact.md`](../runbooks/thanos-compact.md).
- [ ] Replace the misleading `Compactor Halted` Grafana panel with
  one based on `up{job="thanos-compact"}` plus a separate
  `thanos_compact_halted` gauge panel.
- [ ] Review Alertmanager `repeat_interval` for CRITICAL routes.
  Consider `repeat_interval: 4h` for CRITICAL and rely on the
  auto-remediate `ThanosCompactAutoRemediated` alert as the
  positive signal that the situation is being handled.
- [ ] File a fresh report against upstream issue #8611 with the
  R2-sha256-stable and `bucket verify`-clean evidence gathered
  here. Consider raising the `expected:0` variant (mode 2) as
  a separate issue against sidecar rather than compactor.
- [ ] Add a Prometheus recording rule for
  `thanos_compact_halted` state duration and a separate alert
  on that, so we don't rely solely on the compactor emitting
  from its `/metrics` endpoint (which becomes stale when the
  process is stopped).

---

## Appendix: recovery cheatsheet

For the tired-at-3-AM reader who just wants the fix. Full detail
is in [`docs/runbooks/thanos-compact.md`](../runbooks/thanos-compact.md).

**Find the bad block:**

```bash
sudo journalctl -u thanos-compact --since "2 hours ago" --no-pager \
    | grep -iE "critical error|halting|checksum|out.of.order" | tail -5
```

**Downsample failure** (`downsample block <ULID>` in logs):

```bash
sudo thanos tools bucket mark \
    --id=<ULID> \
    --objstore.config-file=/etc/thanos/objstore.yml \
    --marker=no-downsample-mark.json \
    --details="manual: $(date -u +%FT%TZ)"

sudo systemctl reset-failed thanos-compact
sudo systemctl start thanos-compact
```

**Compact-populate failure** (`from block <ULID>` in logs, or
`thanos_compact_halted=1`):

```bash
sudo thanos tools bucket mark \
    --id=<ULID> \
    --objstore.config-file=/etc/thanos/objstore.yml \
    --marker=no-compact-mark.json \
    --details="manual: $(date -u +%FT%TZ)"

# Do NOT use `systemctl restart` on a halted process — it hangs.
sudo systemctl kill --signal=SIGKILL thanos-compact
sleep 3
sudo systemctl reset-failed thanos-compact 2>/dev/null || true
sudo systemctl start thanos-compact
```

**Verify recovery:**

```bash
sleep 30
sudo systemctl status thanos-compact --no-pager | head -5
curl -s http://localhost:19194/metrics | grep "^thanos_compact_halted "
```

Expect `active (running)`, `thanos_compact_halted 0`.

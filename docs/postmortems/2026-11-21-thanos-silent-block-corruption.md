# Postmortem: Silent Thanos block corruption, hidden by auto-remediation

- **Date:** 2026-11-18 to 2026-11-21 (investigation); corruption active
  since at least 2026-08-04
- **Duration:** ~3.5 months of silent impact; ~40 hours of hands-on
  investigation and repair
- **Impact:**
  - **2026-10-11 .. 2026-11-01: long-term metrics permanently lost** at
    every resolution. Raw blocks were deleted by 15d raw retention before
    any 5m/1h copy existed.
  - **2026-11-01 .. 2026-11-14: no 5m/1h copy will ever exist.** Raw
    blocks are corrupt (individual series unreadable) and expire around
    2026-12-12.
  - **2026-11-14 00:00 .. 16:00: raw lost**, 5m copy exists from 16:00.
  - 40 blocks marked `no-downsample` / `no-compact` by automation between
    2026-08-04 and 2026-11-19, none reviewed by a human.
  - No impact on ingestion, alerting or recent (< 2d) queries.
- **Detection:** two `ThanosCompactDown` alerts at 22:36 on 2026-11-18
  and a `ThanosAutoRemediateRateLimit` that the automation could not
  suppress. Everything before that was absorbed by auto-remediation.
- **Blameless framing:** every individual step here was reasonable when
  it was taken. The failure is in how the pieces interacted, and in a
  diagnosis ("known upstream Thanos bug") that made each new occurrence
  look routine.

## Summary

The Thanos compactor on the homelab Raspberry Pi 5 had been producing
corrupt blocks since at least August. The August postmortem attributed
the checksum errors to a long-standing upstream read-path bug and added
a script that marked the offending block (`no-downsample-mark.json` or
`no-compact-mark.json`) and restarted the compactor. That made every
later occurrence look like the same known bug with a known fix.

What the marker actually does: a raw block marked `no-downsample` never
gets a 5m or 1h copy, and raw retention (15d at the time) deletes it.
From mid-October almost every 48h block the compactor produced was
corrupt, so almost every range was marked and then deleted. The script
reported "recovery successful" each time.

The rate of corruption increased sharply after 2026-09-26, when an HA
Prometheus replica on OCI was added and the compactor started vertical
compaction (`--deduplication.replica-label=replica`) across both
replicas, which roughly doubled its working set on an 8 GB Pi with zram
swap.

On 2026-11-20 an unrelated Python CronJob on the same host failed with
`source code string cannot contain null bytes` while importing a library
file that is byte-for-byte intact on disk, and a freshly compacted block
contained ASCII `.com` where a chunk CRC should be. Thanos is not the
common factor; the host's memory path is.

## Auto-marked blocks by creation month

From `/var/lib/thanos-remediate/mark.log` (ULID creation time, PST):

| Month | Blocks marked |
|-------|---------------|
| 2026-08 | 4 |
| 2026-09 | 5 (2 before, 3 after the HA replica on 09-26) |
| 2026-10 | 14 |
| 2026-11 (to the 19th) | 17 |

From 2026-10-15 a corrupt block was produced on essentially every
evening compaction run (21:30-22:30, every two days).

## Timeline (PST)

**2026-08-04 .. 08-06** - Three checksum incidents. Investigation finds
R2 objects stable across reads, `bucket verify` clean, no dmesg/EDAC
events, and matching upstream issues. Conclusion: upstream Thanos bug.
Auto-remediation script deployed.

**2026-09-06** - Thanos 0.41 -> 0.42.4. Error wording changes; script
gets a new parser on 10-12.

**2026-09-26** - HA replica B on OCI goes live. Sidecar B uploads to the
same bucket with `--shipper.upload-compacted`. Compactor gets
`--deduplication.replica-label=replica`.

**2026-10-11 .. 11-01** - Compaction effectively stalls behind marked
blocks; raw for this window ages out at 15d with no 5m copy. Nobody
notices: the marking alerts say "recovery successful".

**2026-11-18 22:04 / 22:14** - Two corrupt compactor outputs. Script
marks the first; the second exhausts its 5-actions-per-hour limit.
`ThanosCompactDown` and `ThanosAutoRemediateRateLimit` reach Telegram.

**2026-11-18 22:53** - Both blocks marked manually, compactor recovers.

**2026-11-19 06:00 .. 06:40** - Compactor rebuilds ~45 blocks covering
11-06 .. 11-19, mixing a late replica-B backlog into already-compacted
ranges. Two more outputs are corrupt. Compactor and remediation timer
stopped manually.

**2026-11-19 07:20** - `bucket verify` finds 7 overlapping pairs: an old
lineage and a new one built from late replica-B blocks. Working theory:
vertical compaction with one-to-one dedup (wrong mode for HA replicas
with offset scrape times) is producing the corruption.

**2026-11-19 07:25** - Corrupt and duplicate blocks soft-deleted.
Compactor config: no replica-label dedup, raw retention 15d -> 30d.
Compactor halts on overlap anyway: deletion marks are ignored only after
`delete-delay / 2` (24h). Wait.

**2026-11-20 12:50** - Compactor restarted, clean cycle. Downsampling
reports `todo_downsample_blocks 5` but downloads nothing.

**2026-11-20 16:45, 17:00** - Two `iptv-*` CronJob pods fail with NUL
bytes in `redis/commands/core.py`. Later runs of the same image succeed;
the file on disk is clean in all 19 snapshots.

**2026-11-21 00:40 .. 09:06** - Host checks: no PCIe overclock, no
CPU/RAM overclock, `get_throttled=0x0`, NVMe SMART clean, no kernel
errors. `stressapptest` 30 min on 1 GiB: PASS. Bootloader EEPROM found
six months out of date (2025-12-08 vs 2026-05-26).

**2026-11-21 09:06** - EEPROM updated, first reboot in 130 days.

**2026-11-21 09:09** - A block built at 07:58 that morning, on the old
firmware and **without** vertical compaction, fails downsample with
`checksum mismatch expected:2e636f6d` (ASCII `.com`). Vertical
compaction is not the root cause.

**2026-11-21 09:24** - `no-downsample` markers found on all five live
raw blocks for 11-01 .. 11-12 (set by the script earlier). The gauge
`thanos_compact_todo_downsample_blocks` counts marked blocks; the
downsampler silently skips them, even at debug log level. Markers
removed one by one: all five fail downsample with checksum errors.

**2026-11-21 09:50** - Replica-B uploads disabled on OCI; R2 key removed
from the VM; remaining replica-B blocks deleted.

**2026-11-21 10:00 .. 10:16** - Detection-only detector deployed,
`ThanosCompactDownsampleBacklog` alert added, persistent journald fixed,
R2 key rotated.

## Root cause

Not fully established. What the evidence supports:

1. **Data is being corrupted in memory on the Pi 5**, then written out
   faithfully. Evidence: deterministic checksum failures on blocks the
   compactor itself wrote; foreign data (`.com`, zeros) where CRCs belong;
   NUL bytes returned for an intact file in page cache for ~15 minutes;
   none of it visible to the NVMe, the kernel or SMART. Prometheus WAL
   corruption since July (`unexpected non-zero byte in padded page`),
   previously attributed to upstream issue #16074, fits the same pattern.
2. **Corruption scales with memory pressure.** The rate jumped when
   vertical compaction doubled the compactor's working set. The host ran
   with ~2 GiB available and swap (zram, compressed RAM) in use.
3. **Candidate mechanisms**, in order of what to test next: outdated
   bootloader SDRAM init (fixed 2026-11-21, under observation); a RAM
   fault outside the 1 GiB tested; zram/zsmalloc under pressure.

The August "upstream Thanos bug" diagnosis was wrong or incomplete. It
rested on evidence that does not rule out corruption at write time:
`bucket verify` reads only the index, and stable R2 reads only prove the
object did not change after upload.

## Contributing factors

- **Automation that removes the symptom instead of reporting it.** The
  script turned a data-integrity signal into a routine "succeeded"
  notification. A marker is a retention decision; automating it made
  that decision 40 times without review.
- **A confident diagnosis that explained away every recurrence.** Once
  "known upstream bug" was in the runbook, a rising rate looked like
  noise, not trend.
- **Raw retention too short for a stalling compactor.** 15d left no
  margin between "block stuck" and "block deleted".
- **A metric that hides the problem.** `todo_downsample_blocks` included
  marked blocks, so it was flat and uninteresting, while the downsampler
  logged nothing about skipping them.
- **Late uploads from replica B** (`--shipper.upload-compacted` on a
  Prometheus with local compaction enabled) created a second lineage
  that forced the compactor to rebuild history.
- **Volatile journald.** Raspberry Pi OS ships `Storage=volatile`; the
  2026-09-15 persistent drop-in never took effect because journald was
  not restarted. Logs older than ~3 days, including the script's marking
  history before Thursday, were gone. `mark.log` survived only because
  the script wrote its own file.
- **Duplicate alerting.** Each script event fired twice (direct webhook
  and Prometheus rule on its counter), training the reader to skim.

## What went well

- Stopping the compactor early on 11-19 kept deletion-marked sources
  alive, which made every later decision reversible.
- ULID timestamps turned "some blocks are bad" into a timeline in
  minutes.
- The unrelated CronJob failure was read as evidence, not noise.

## Changes made (2026-11-21)

| Change | Where |
|--------|-------|
| Detector is detection-only: one `ThanosCompactCorruptBlock` alert per (block, stage) per 24h, no markers, no restarts | `system/thanos-compact-remediate/` |
| Prometheus twins of script alerts removed | `prometheus/rules/thanos-alerts.yml` |
| `ThanosCompactDownsampleBacklog`: raw blocks without 5m for 6h+ (silenced to 2026-12-15 for the five known November blocks) | `prometheus/rules/thanos-alerts.yml` |
| Compactor: no replica-label dedup, raw retention 30d | `system/thanos/thanos-compact.service` |
| Replica B: no R2 upload, R2 key removed from the VM | `system/prometheus-oci/` |
| R2 key rotated (`thanos-homelab-v5`), old token deleted | Cloudflare |
| Persistent journald, RPi OS volatile default masked | `system/journald/` |
| Bootloader EEPROM 2025-12-08 -> 2026-05-26 | Pi |

## Action items

- [ ] **Watch the next two weeks.** Success: `thanos_compact_downsample_total{resolution="0"}`
  grows, `downsample_failures_total` stays 0, no `ThanosCompactCorruptBlock`,
  no WAL corruption in Prometheus.
- [ ] If corruption returns: disable zram (`/etc/rpi/swap.conf`), then a
  long `stressapptest -M 5000` with the stack stopped. If that fails,
  move compactor and Prometheus off the Pi.
- [ ] Install rules from the repo instead of hand-copied files in
  `/etc/prometheus/rules` (same drift class as the remediation unit on
  10-12).
- [x] Pointer added to `2026-08-05-thanos-compact-checksum-cascade.md`.
- [ ] Correct
  `2026-09-14-slo-rules-rolling-window-gaps.md` (WAL corruption) with a
  pointer here.
- [ ] Three small live blocks (`01M6NB2N`, `01M7T1HP`, `01M7D5SQ`) carry
  `no-compact` and are under 40h, so they can never be downsampled. Decide
  whether to remove the markers; otherwise they expire with the rest.

## Lessons

1. A checksum error is evidence of corruption until proven otherwise.
   "Known upstream bug" needs evidence that rules out the host.
2. Automation may restart things. It must not make retention decisions.
3. Track the rate, not the incident. Four per month and seventeen per
   month look the same one alert at a time.
4. Check that a config change took effect, not just that the file exists.

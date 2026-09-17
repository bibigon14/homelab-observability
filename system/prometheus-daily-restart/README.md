# prometheus-daily-restart

Systemd timer that restarts Prometheus daily at 04:00 PDT
(with 15-minute randomized delay) to work around upstream
WAL checkpoint corruption bug.

## Background

Upstream Prometheus issue https://github.com/prometheus/prometheus/issues/16074
(open since Feb 2025, also #17493, #7299, #6898) - WAL
checkpoint creation intermittently fails with
`unexpected non-zero byte in padded page` or
`unexpected checksum` on segments accumulated over long
uptime windows. Not fixed upstream, reproduces on arm64
and amd64, on ext4/JuiceFS/NFS.

Restart clears WAL and lets replay skip corrupted segments.
Cost is 5-15 min of head-only metrics per day (blocks
already flushed to disk/Thanos are safe).

## History

- 2026-08-14: initial weekly restart added after WAL
  corruption incident that produced 24GB WAL and 97.5%
  checkpoint failure rate over a month.
- 2026-09-06: switched from weekly to daily. Weekly cadence
  itself hit the bug at 04:00 during its own compaction.
  448MB WAL grew in 3h20min after restart = ~135MB/h,
  meaning ~22GB/week - back in the corruption-prone zone.
  Daily caps WAL at ~3GB.

## Install

    sudo cp prometheus-daily-restart.{timer,service} /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now prometheus-daily-restart.timer
    systemctl list-timers prometheus-daily-restart.timer

## 2026-09-16: disabled - the workaround was causing daily data loss

Investigation into a daily ~65 minute gap in every SLO recording rule
(10:05-11:14 UTC, always ending exactly at the restart) traced back to
this timer.

The mechanism: #16074 corrupts a WAL segment during a checkpoint cycle.
Prometheus keeps running fine afterwards - rule evaluations fire,
samples land, everything is queryable in real time. The damage only
lands on the next startup:

    level=WARN msg="Encountered WAL read error, attempting repair"
              err="corruption in segment 00000072 at 33177751"
    level=WARN msg="Deleting all segments newer than corrupted segment" segment=72
    level=INFO msg="Successfully repaired WAL"

On 2026-09-16 the corrupt segment was 72 and maxSegment was 83, so
eleven segments were deleted - roughly one hour of data erased
retroactively, every day, at restart time.

Confirming detail: 2026-09-11 was the only day in a week with no
restart, and the only day with no gap.

So the cost of this workaround is not "5-15 min of head-only metrics"
as estimated above. It is closer to 60 minutes per day, and it lands
after the fact, which is why it looked like a recording-rule bug for
two days. See docs/postmortems/2026-09-14-slo-rules-rolling-window-gaps.md.

### Current state - unresolved trade-off

Timer disabled, WAL and chunks_head wiped clean (backups kept as
`/var/lib/prometheus/metrics2/{wal,chunks_head}.old-20260916`).

This is not a fix. The WAL growth documented above (~135MB/h, ~22GB/week)
has not gone away. Without periodic truncation the WAL will climb back
into the range where the corruption rate got bad (24GB / 97.5% failures
in Aug 2026).

Under observation:

- does the checkpoint still fail on a fresh WAL
- WAL growth rate: `du -sh /var/lib/prometheus/metrics2/wal`
- Prometheus RSS: `systemctl show prometheus --property=MemoryCurrent`

If the WAL climbs past a few GB, the options are a Prometheus upgrade
to a release where #16074 is fixed, or a restart cadence somewhere
between daily and weekly - accepting the data loss but less often.
Re-enabling the daily timer restores the daily gap.

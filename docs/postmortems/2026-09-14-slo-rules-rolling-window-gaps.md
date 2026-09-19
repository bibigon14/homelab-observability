# A daily restart meant to work around a WAL bug was deleting an hour of data every day

**Date**: 2026-09-14 to 2026-09-17
**Time to root cause**: ~8 hours of investigation across three days
**Severity**: one hour of metrics lost per day, silently, for about six weeks
**Author**: Dmitry Stepanov

## Summary

Every SLO panel on the homelab Grafana dashboard had a vertical gap at the
same wall-clock time every day: roughly 10:05 to 11:14 UTC, about 65
minutes wide. Recording rules reported healthy. No evaluation was ever
missed. Prometheus logged nothing unusual during the window.

The cause was `prometheus-daily-restart.timer` - a workaround this repo
added in August for upstream
[prometheus#16074](https://github.com/prometheus/prometheus/issues/16074),
a WAL checkpoint corruption bug. The bug corrupts a WAL segment during a
checkpoint cycle. Prometheus keeps running normally afterwards. The damage
only lands on the *next startup*, when WAL replay hits the corrupt segment
and deletes every segment written after it.

So the restart that was supposed to contain the bug was instead cashing it
in once a day, erasing the hour of data between the corruption and the
restart.

The investigation took as long as it did because the data was present and
queryable the entire time Prometheus was running. It only disappeared
retroactively. Every check ran after the fact and saw a hole that had not
existed while the window was live.

## Timeline

### Day 1 - 2026-09-14

- **08:00 PDT** Noticed vertical gaps on Service Error Budget Remaining
- **08:15** Hypothesis 1: WAL corruption blocking rule evaluation. Ruled
  out - checkpoint failures were logged every 2h, gaps were daily
- **08:25** Hypothesis 2: chaos-monkey killing pods mid-evaluation. Ruled
  out - chaos-monkey runs hourly, gaps were daily
- **08:32** Hypothesis 3: Velero backup causing series churn. Ruled out -
  the backup runs at 03:00 UTC and finishes in 34 seconds
- **08:37** Hypothesis 4: corrupted Thanos block at the 7d window edge.
  Ruled out - `promtool tsdb analyze` came back clean on every block
- **08:45** Hypothesis 5: a 7-minute gap in `up{job=node}` on Sep 8,
  projected forward daily by the 7d rolling window
- **09:01** Deployed a fix for hypothesis 5: rewrote four recording rules
  from `avg_over_time(X[7d])` to `sum_over_time(X[7d]) / count_over_time(X[7d])`
- **09:03** All rules healthy after reload. Wrote the first version of this
  postmortem describing hypothesis 5 as the root cause

### Day 2 - 2026-09-15

- **13:09** The gap appeared again, same window, 64 minutes. The fix had
  done nothing
- **13:20** Hypothesis 6: the recording rules were only deployed on Sep 8,
  so the 7d window had never held a full week of data. Appeared to be
  confirmed by an `absent()` check returning zero
- **13:30** That confirmation was a measurement error - the check covered a
  window *after* the daily gap, not during it
- **13:30 to 17:30** Four more hours. Ruled out cadvisor series churn,
  kubelet garbage collection, CPU and IO contention (both under 1%), rule
  evaluation latency (p99 under 200ms), ArgoCD sync, and Velero
- **17:30** One correlation survived everything: the gap appeared on days
  the restart timer fired and not on 2026-09-11, the only day in the week
  without a restart. But the restart happened at the *end* of the gap, an
  hour after it started, so it looked like the thing that fixed the gap
  rather than the thing that caused it
- **17:32** Reverted the recording rule change - it had been neutral
- **17:40** Switched journald to persistent storage. Until then it was
  volatile on tmpfs and rotated every 3-4 days, so every attempt to read
  logs from the gap window came back empty

### Day 3 - 2026-09-16

- **10:14** With persistent logs available, pulled the full restart
  sequence and found it:

      level=WARN msg="Encountered WAL read error, attempting repair"
                err="corruption in segment 00000072 at 33177751"
      level=WARN msg="Starting corruption repair" segment=72
      level=WARN msg="Deleting all segments newer than corrupted segment" segment=72
      level=INFO msg="Successfully repaired WAL"

  `maxSegment` was 83. Segment 72 was corrupt. Segments 73 through 83 were
  deleted - about an hour of data, erased at restart time
- **20:43** Wiped WAL and chunks_head, disabled the restart timer
- **22:11** Found that thanos-sidecar had been dead for 90 minutes: it has
  `Requires=prometheus.service`, so stopping Prometheus stopped it, but
  starting Prometheus did not bring it back. Added a drop-in with
  `Wants=thanos-sidecar.service`

### Day 4 - 2026-09-17

- **09:36** Two checkpoints in a row completed successfully on the fresh
  WAL - 02:00 and 06:00 UTC, no corruption. WAL truncation working,
  segments 0 through 3 usefully reclaimed. Zero gap minutes overnight

## The mechanism

The confusing part is the ordering. Written out:

1. A checkpoint cycle corrupts a WAL segment (upstream bug #16074)
2. Prometheus carries on. Rule evaluations fire on schedule.
   `prometheus_rule_group_last_evaluation_samples` reports 39 samples per
   minute for the SLO group. `prometheus_tsdb_head_samples_appended_total`
   climbs normally. Every query against the live instance returns data
3. The restart timer fires
4. WAL replay hits the corrupt segment, deletes everything after it, and
   reports success
5. The data written between steps 1 and 3 is gone

From the outside this looks like a gap that starts an hour before the
restart and ends exactly at it. It never looked like the restart caused it,
because the restart appeared to be the moment things got better.

## Why it took three days

**The evidence contradicted itself, and both halves were true.**

- Rule health: `ok`
- `prometheus_rule_group_iterations_missed_total`: 0
- `prometheus_rule_group_last_evaluation_samples`: 39, every minute,
  through the entire window
- `absent(slo:service:error_budget_remaining_7d)`: 1, for the same minutes

Both were correct. The rules did produce 39 samples per minute. Those
samples did get written. They were deleted later.

**Every measurement was taken after the fact.** A probe running *during*
the window would have shown the data present and closed this on day one.
That check was never run, because there was no reason to think data that
exists now might not exist later.

**Logs were unavailable exactly where they mattered.** journald was on
volatile storage with a 3-4 day retention. Every attempt to read the gap
window returned `-- No entries --`. The decisive log line was in the
restart sequence the whole time.

**The restart timer was never a suspect.** It was installed in August as
the fix for this class of problem, documented, and mentally filed as part
of the solution. Six hypotheses went by before anything pointed at it, and
even then the timing looked backwards.

**A plausible fix shipped on day one.** Rewriting `avg_over_time` as
`sum_over_time / count_over_time` was defensible, passed `promtool check`,
and deployed cleanly. It changed nothing, because the rules were never the
problem. It also anchored the next day's thinking on the rules.

## Fix

- `prometheus-daily-restart.timer` disabled
- WAL and chunks_head wiped clean, backups kept as `*.old-20260916`
- Drop-in adds `Wants=thanos-sidecar.service` to `prometheus.service` so
  the dependency works in both directions
- Recording rule change from day 1 reverted - it was neutral

Two checkpoints have since completed successfully on the fresh WAL with no
corruption, and WAL truncation is reclaiming segments. The corruption
appears to have been a property of the accumulated WAL rather than
something that reproduces on a clean one.

## This is a trade-off, not a resolution

The restart timer existed for a reason. From the original notes in
`system/prometheus-daily-restart/README.md`:

- 2026-08-14: WAL corruption incident produced a 24GB WAL and a 97.5%
  checkpoint failure rate over a month
- 2026-09-06: weekly restart was not enough - WAL grew ~135MB/h, about
  22GB/week, back into the range where corruption got bad

Current growth on the clean WAL is roughly 20MB/h with truncation working,
which is a different regime entirely. But if the corruption comes back and
truncation stops, the WAL will climb again and something will have to give.

Being watched:

- whether checkpoints keep succeeding
- `du -sh /var/lib/prometheus/metrics2/wal`
- `systemctl show prometheus --property=MemoryCurrent`

If the WAL climbs past a few GB the options are upgrading Prometheus to a
release where #16074 is closed, or a restart cadence between daily and
weekly - accepting the data loss, just less often. Re-enabling the daily
timer restores the daily gap.

## What to do differently

**Probe during the incident window, not after it.** Two days of this
investigation were spent querying a window that had already been rewritten.
A cron job hitting `/api/v1/query` every five minutes during the window
would have shown the data present and pointed straight at the restart.

**Persistent logs are not optional on a box you investigate.** Default
journald on this Pi was volatile, on tmpfs, rotating every few days. The
decisive log line was available for about four days after each restart and
nobody read it in time. Now fixed:
`Storage=persistent`, `SystemMaxUse=1G`, `MaxRetentionSec=30days`.

**Workarounds deserve the same scrutiny as the bugs they paper over.** This
one was installed, documented, and then treated as settled infrastructure.
It was the last thing anyone suspected, and it was the answer. A workaround
that runs on a timer and mutates state should carry an explicit note about
what it costs when it fires.

**A fix that does not change the symptom is information.** The recording
rule rewrite on day 1 was reverted on day 2, but the day it spent deployed
without changing anything should have been treated as evidence against the
whole rule-level theory sooner than it was.

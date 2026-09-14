# SLO dashboard shows daily gaps that trace back to a 7-day-old outage

**Date**: 2026-09-14  
**Duration of investigation**: ~2h  
**Severity**: cosmetic - no data lost, no alerts missed, no SLO breach  
**Author**: Dmitry Stepanov

## Summary

The homelab SLO Error Budgets dashboard showed vertical gaps on every
panel, once per day, at wall-clock time 03:04 PDT (10:04 UTC), lasting
about 66 minutes. Investigation went through five hypotheses before
landing on the correct one: a 7-minute scrape gap in `up` from Sep 8
was propagating through the 7-day rolling window of the recording rules
and producing empty result vectors for a slice of every subsequent day.

No data was actually lost. Prometheus rule evaluations ran on schedule.
The rules just returned empty vectors, which Prometheus stores as
"nothing" rather than as an error, and Grafana rendered as gaps.

## Timeline

- 08:00 PDT: Noticed gap on Service Error Budget Remaining panel
- 08:15 PDT: First hypothesis - WAL corruption bug #16074 blocking rule eval
- 08:20 PDT: Ruled out - checkpoint fails every 2h but gaps daily, not every 2h
- 08:25 PDT: Second hypothesis - chaos-monkey killing pods during eval
- 08:30 PDT: Ruled out - chaos runs hourly, gaps daily
- 08:32 PDT: Third hypothesis - Velero backup triggering series churn
- 08:35 PDT: Ruled out - backup runs at 03:00 UTC and takes 34 seconds
- 08:37 PDT: Fourth hypothesis - Thanos block corruption at 7d window edge
- 08:40 PDT: Ruled out - promtool tsdb analyze clean, all blocks intact
- 08:45 PDT: Fifth hypothesis - Prometheus daily restart creates gap in `up`
- 08:50 PDT: Confirmed a 7-min gap in `up{job=node}` on Sep 8 11:04-11:11 UTC
- 08:52 PDT: Discovered journald had rotated - original cause unrecoverable
- 08:55 PDT: Understood mechanism - rolling 7d window projects old gap forward
- 09:01 PDT: Deployed fix (sum_over_time / count_over_time)
- 09:03 PDT: All rules health=ok after reload

## What went wrong

Recording rule `slo:service:error_budget_remaining_7d` used this expression:

~~~promql
1 - ((1 - avg_over_time(up{...}[7d])) / (1 - 0.999))
~~~

Under a specific set of conditions on Prometheus 3.14 (needs upstream
investigation), `avg_over_time` over a 7d window returned an empty
vector when the underlying series had certain kinds of gaps 7 days back.
The empty result:

- Was accepted silently by Prometheus (no error, no failure counter)
- Left `prometheus_rule_group_iterations_missed_total` at zero
- Left rule `health` at `ok`
- Produced zero samples in TSDB for the affected evaluation cycles

The underlying gap in `up` was 7 minutes long. The visible gap in the
SLO dashboard was ~66 minutes long, because the 7d rolling window kept
catching the same 7-min hole for every evaluation across that hour.

## Why it took 2 hours

Five wrong hypotheses in a row, each one plausible given prior context
of the homelab. The right diagnosis needed:

1. Checking `absent()` over the full 7d window, not just recent hours
2. Comparing timing of gaps against systemd timer schedule
3. Cross-referencing recording rule health metrics with actual TSDB
   sample writes (they disagreed)
4. Running the rule expression manually with `@time` modifier at
   the exact gap timestamp to compare with what the rule produced

Journald had rotated (default volatile storage on `/run` tmpfs), so
logs from 6 days ago were unrecoverable. Made root-cause of the
original 7-min scrape gap impossible to determine.

## Fix

Replaced `avg_over_time(X[7d])` with `sum_over_time(X[7d]) / count_over_time(X[7d])`
in four recording rules. Mathematically equivalent when data is present.
Stays defined when it isn't.

Alert rules with shorter windows (5m to 6h) kept as `avg_over_time`
because absence in a short window means a real outage, not a
rolling-window artifact.

## What to do differently

**Immediate**: enable persistent journald storage (`Storage=persistent`
in `/etc/systemd/journald.conf`) so next time a downtime happens we
can trace the cause instead of guessing.

**Medium term**: add a Prometheus alert on `absent()` of the SLO
recording rules themselves. If the rule stops writing samples, the
dashboard hides the problem instead of surfacing it. An explicit
`absent()` alert would have surfaced this within an hour of the
first missed evaluation instead of a week later.

**Long term**: consider moving 7d SLO computation to Thanos Ruler
against store gateway data. Rolling windows over local head data are
fragile to short scrape gaps. Rolling windows over compacted blocks
in object storage are not.

# ADR: HA Prometheus with OCI arm64 replica over WireGuard

- Status: Accepted
- Date: 2026-09-25
- Deciders: Dmitry
- Supersedes / relates to:
  - `2026-08-13-prometheus-wal-corruption-recovery.md`
    (weekly restart timer as workaround for #16074)
  - `2026-09-14-slo-rules-rolling-window-gaps.md`
    (postmortem where daily restart itself was found to cause daily
    65 min gaps)
  - `2026-09-16-daily-restart-disabled.md`
    (workaround disabled under observation)

## Context

Upstream Prometheus bug
[prometheus/prometheus#16074](https://github.com/prometheus/prometheus/issues/16074)
corrupts a WAL segment during a 2h checkpoint cycle. The corruption
is invisible in real time - rule evaluations fire, samples are
appended, everything is queryable - but on the next process restart
WAL replay hits the corrupt segment and truncates every segment
newer than it, retroactively erasing up to two hours of head data.

The observation window that followed the 2026-09-16 fresh WAL wipe
closed on 2026-09-25 with the predicted result: the new WAL
developed the same corruption pattern within 24h and 8 days later
had 7.1 GB of untruncated segments. Restarting to reclaim WAL
disk then costs another retroactive gap.

The bug has been open in upstream since Feb 2025. It reproduces
across Prometheus 2.15 -> 3.14 and multiple architectures. No fix
in the current release (3.14.0, Aug 2026). Most production
deployments do not feel it because they already run HA pairs behind
Thanos or Mimir dedup; the homelab has been feeling it because it
runs single-instance.

Every workaround we have tried on a single instance trades one
harm for another:

| Approach          | Cost                                              |
|-------------------|---------------------------------------------------|
| No restart        | WAL grows unbounded, eventually OOM               |
| Daily restart     | ~65 min retroactive gap in dashboards every day   |
| Reactive restart  | Same retroactive gap, only timing is different    |
| WAL wipe          | Same as above plus loses recent head              |

## Decision

Deploy a second Prometheus (replica B) on the OCI Ampere A1 arm64
VM that already hosts `ebpf-tcp-observer`, scraping the same
homelab targets over the existing WireGuard tunnel, both replicas
shipping to the same Thanos R2 bucket, and enable Thanos Query
dedup on the `replica` external label.

Layout:

```
Pi (replica A)         OCI Ampere A1 (replica B)
+----------------+     +---------------------------+
| Prometheus     |     | Prometheus                |
|   external:    |     |   external:               |
|     replica: a |     |     replica: b            |
+--------+-------+     +------------+--------------+
         |                          |
         | ship blocks              | ship blocks
         v                          v
              +----------------+
              |   R2 bucket    |
              +--------+-------+
                       |
                       v
              +----------------+
              | Thanos Query   |  --query.replica-label=replica
              +--------+-------+
                       |
                       v
                   Grafana
```

When either replica has a gap (restart, WAL truncation, host
outage, tunnel blip), Thanos Query serves from the other. The
`replica` label is stripped at dedup time, so downstream queries
and dashboards do not need to know about it.

## Alternatives considered

### A. Keep restart-based workaround

Rejected. Two months of observation showed both the daily and the
disabled-restart states are worse than living with the bug: the
former loses ~65 min of data a day retroactively, the latter grows
WAL until intervention. Reactive restart triggered by
`prometheus_tsdb_checkpoint_creations_failed_total` was the last
variation left to try - it just moves when the gap happens, not
whether.

### B. Same-host HA pair (two Prometheus on the Pi)

Rejected. RAM budget is 7.9 GB total, 5.3 GB currently used, one
Prometheus peaks at 1 GB - two would fit only with swap use. More
importantly, shared hardware and kernel means a single event
(power blip, kernel panic, filesystem issue, upgrade) takes down
both replicas simultaneously and the HA benefit disappears exactly
when needed. Interview story is also weaker: "budget-constrained
HA on one box" versus "HA across two hosts, two networks, two
regions".

### C. Full migration to VictoriaMetrics

Rejected for now. VM eliminates the bug class (different TSDB
engine, different failure modes), typically halves memory use, and
keeps PromQL and Grafana as-is. It is the right long-term direction.
Not chosen today because:

- The homelab has non-trivial invested state in Thanos: R2 bucket,
  compactor, sidecar shipping, downsampling
- Grafana dashboards and 10 rule groups have been tuned against
  Thanos Query semantics (dedup timing, staleness)
- A weekend migration under interview time pressure is a bad idea

Filed as a follow-up; the HA pair does not block that migration and
the R2 blocks are portable.

### D. Prometheus in agent mode + remote_write to a receive backend

Rejected. Removes WAL from the client side but requires standing up
a receive backend somewhere (Thanos Receive, VictoriaMetrics
vminsert, Grafana Mimir). That is a bigger project than option C
with none of C's upside.

## Consequences

### Positive

- Single-replica gaps become invisible to Grafana / SLO rules
- Better failure-domain separation than same-host HA: different
  hardware (Pi 5 vs Ampere A1), different power, different ISPs,
  different filesystems
- `#16074` symptoms are contained rather than fixed - the bug can
  fire on either replica without the user noticing
- Meta-monitoring gains: each replica scrapes the other's
  Prometheus / sidecar, so a full outage on one host shows up in
  the surviving replica's alerts
- Interview material: real cross-host HA with a WireGuard
  boundary, real Thanos dedup, real trade-off analysis rather than
  a textbook example

### Negative

- Second Prometheus doubles scrape load on the homelab targets
  (unimportant at homelab scale; noted for completeness)
- Second sidecar doubles R2 PUT operations on block upload
  (~2 blocks / hour extra; R2 free tier absorbs it)
- WireGuard becomes a hard dependency for HA - a tunnel outage
  drops OCI's scrape and reduces the pair back to a single replica
- Deploy is currently manual on the OCI side (Pi has a sync timer,
  OCI does not yet)
- Shared R2 credentials between Pi and OCI - operationally simpler
  today, cleaner audit trail would be per-replica keys

## Follow-ups

Tracked out of this ADR as GitHub issues on the repo:

1. Add a sync timer on OCI equivalent to the one on Pi
   (`homelab-observability-sync.service/timer`), so rule file
   changes propagate automatically
2. Rotate Pi and OCI to separate R2 API tokens
3. Add Pi -> OCI Prometheus scrape symmetrically (Pi's config
   scrapes only `localhost:9090` for prometheus job; adding
   `10.0.0.4:9090` gives full self-monitoring on both sides)
4. Add `PrometheusReplicaStale` meta-alert - fires when either
   replica has not shipped a block to R2 in > 3h
5. Draft VictoriaMetrics migration plan as a separate ADR - HA
   pair is a bridge, not the destination

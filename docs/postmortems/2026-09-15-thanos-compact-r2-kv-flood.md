# thanos-compact defaults exhaust R2 Workers KV free tier after TSDB reinstall

**Date**: 2026-09-15
**Duration of investigation**: ~45 min
**Severity**: cosmetic - no data loss, no service impact, just Cloudflare
alert emails multiple times per day
**Author**: Dmitry Stepanov

## Summary

After the 2026-09-06 Prometheus TSDB reinstall (see the
2026-08-05 Thanos compact checksum cascade postmortem for the
underlying reason), Cloudflare started sending daily "KV daily
operation limit 50% reached" alerts for the R2 bucket backing
Thanos long-term storage. The alerts began 2026-09-04 and
increased in frequency, reaching multiple per day by 2026-09-13.

Root cause: `thanos-compact` runs its BaseFetcher metadata sync on
the shortest of several configurable intervals, and one of them
(`--block-viewer.global.sync-block-interval`) defaults to 1
minute. Each sync issues one LIST plus one GET per block against
the object store. With ~59 blocks in R2 that worked out to
roughly 2600 metadata syncs per day, translating to well over the
Workers KV free-tier cap.

Fix: set four interval flags to 1h. Restart. Verified with
`thanos_blocks_meta_base_syncs_total` before and after.

## Timeline

- 13:30 PDT: Noticed the Cloudflare "KV daily operation limit
  50% reached" emails had gone from occasional to multiple per
  day since early September
- 13:35 PDT: Correlated timing with 2026-09-06 TSDB reinstall,
  which increased local block count
- 13:37 PDT: Counted synchronized-block-metadata log entries
  from thanos-compact - 108 per hour
- 13:41 PDT: First fix attempt - added `--wait-interval=1h`,
  `--compact.cleanup-interval=1h`,
  `--compact.progress-interval=1h`. Restarted. Log rate dropped
  to ~28 per hour, better but not enough
- 13:52 PDT: Read `thanos compact --help` more carefully,
  spotted `--block-viewer.global.sync-block-interval=1m`
  default - the one actually driving the once-per-minute base
  syncs
- 14:39 PDT: Added the fourth flag, restarted
- 14:56 PDT: Verified with `thanos_blocks_meta_base_syncs_total`
  - 6 syncs total over 17 minutes of uptime, all in the initial
  startup burst, then silence. Steady-state ~1 sync per hour
- 15:00 PDT: Committed the unit file change

Checked `thanos-store` and `thanos-sidecar` for the same
pattern. Store's sync rate was already reasonable (~4/hour, a
different code path). Sidecar's shipper does not repeatedly scan
the bucket. Neither needed a change.

## What went wrong

Nothing broke. `thanos-compact` was doing exactly what its
defaults told it to do. The defaults just do not assume the
operator is paying per bucket operation.

Four intervals control how often the compactor talks to the
object store:

- `--wait-interval=5m` - between full compaction cycles when
  `--wait` is set
- `--compact.cleanup-interval=5m` - between partial-upload
  cleanup passes
- `--compact.progress-interval=5m` - between progress-metric
  refreshes
- `--block-viewer.global.sync-block-interval=1m` - the base
  fetcher sync driving the actual once-per-minute rate

The block-viewer flag is easy to miss because the name suggests
it applies only to the built-in UI. It does not - it sets the
base BaseFetcher sync interval used by the whole compact loop.

Multiplied by ~59 blocks (each sync lists the bucket plus reads
one meta.json per block), the sync rate translated to enough R2
class B operations per day to trip the Workers KV 50% free-tier
alert repeatedly.

The reason the alerts started in September and not earlier: the
2026-09-06 reinstall meant Thanos had to re-upload every block
of local Prometheus history, so block count grew quickly over
the following week. More blocks per sync = more operations per
sync.

## Fix

Set all four intervals to 1h in `system/thanos/thanos-compact.service`:

~~~
--wait-interval=1h
--compact.cleanup-interval=1h
--compact.progress-interval=1h
--block-viewer.global.sync-block-interval=1h
~~~

`thanos_blocks_meta_base_syncs_total` went from ~108/hour to
~1/hour outside the startup burst, about 85x reduction.
Downsampling and retention still run - just less often, which
is fine for a homelab where blocks are 2h wide.

For a homelab this is comfortably inside R2 free tier. For
anything larger, or if the same alerts start appearing again
later, moving to Workers Paid ($5/month, 10M reads and 1M
writes per month) removes the tuning treadmill entirely.

## What to do differently

**Check upstream defaults against object store pricing at
install time.** Prometheus and Thanos both assume the operator
knows what "5m" means in operations-per-day and dollars-per-
month. Neither doc calls this out. A one-line check
(`thanos-compact --help | grep interval`) at setup would have
saved the alert noise.

**Add an alert on `rate(thanos_blocks_meta_base_syncs_total)`
per component.** If a future upgrade re-introduces a low-
interval default, or if a new component starts syncing
aggressively, the metric moves before the Cloudflare emails
arrive.

**When investigating cost-triggered alerts, sync rate is the
first thing to look at.** Most cloud object stores charge per
LIST/GET. Any long-running process that watches for blob
changes will do this on a timer. That timer is worth auditing
whenever bills or free-tier alerts move.

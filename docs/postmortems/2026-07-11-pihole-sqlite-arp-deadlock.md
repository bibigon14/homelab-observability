# Postmortem: Pi-hole FTL SQLite ARP Deadlock - Recurring DNS Blackout

**Date:** 2026-07-11 | **Duration:** ~4 min/hour, recurring for multiple days | **Severity:** SEV2  
**Author:** Dmitry Stepanov | **Status:** Resolved

---

## Summary

Pi-hole FTL v6.6.2 had a bug where its ARP-parsing thread attempted to open a nested SQLite transaction (`BEGIN` inside an already-open `BEGIN`), causing an `SQLITE_ERROR` every hour at :05. Under normal conditions this failed silently. When Kubernetes CronJobs fired simultaneously at :00, they created multiple `veth` interfaces at once, flooding the ARP table and turning the silent bug into a full SQLite deadlock - blocking DNS resolution for ~4 minutes. The fix was updating Pi-hole FTL to v6.7 and staggering CronJob schedules.

---

## Impact

- All `.homelab.local` DNS resolution failed for ~4 minutes every hour
- `/etc/resolv.conf` fell back to `1.1.1.1`, which returned `NXDOMAIN` for internal hostnames
- Affected services: Uptime Kuma, Grafana, ArgoCD, all homelab-internal endpoints
- HomelabServiceDown alerts fired in Telegram at 00:37 PDT
- Recurred every hour until mitigated

---

## Timeline

| Time (PDT) | Event |
|------------|-------|
| Days prior | Pi-hole FTL v6.6.2 logs `SQLITE_ERROR: cannot start a transaction within a transaction` every hour at :05 - unnoticed |
| 00:37 | Telegram alerts fire: simultaneous HomelabServiceDown for multiple services |
| ~00:37-00:41 | DNS blackout: Pi-hole silent, fallback to 1.1.1.1 → NXDOMAIN for .homelab.local |
| ~00:41 | Services recover automatically as deadlock clears |
| Morning | Investigation begins; FTL.log reviewed |
| Investigation | Correlation found: all CronJobs scheduled at `:00` → simultaneous pod starts → veth flood → ARP storm → SQLite deadlock |
| Fix | `sudo pihole -up` → FTL upgraded to v6.7 (bug fixed upstream) |
| Mitigation | CronJob schedules staggered: `iptv-influx-writer` → `5,35 * * * *`, `chaos-monkey` → `2 * * * *` |
| Confirmed | DNS stable; no further simultaneous failures |

---

## Root Cause

### Technical chain

Pi-hole FTL maintains a SQLite database for DNS query logging and statistics. Every hour at `:05`, FTL's ARP-parsing thread begins processing the ARP table to associate DNS queries with hostnames. This thread calls `BEGIN` to start a transaction - but if another transaction is already open (e.g., from concurrent DNS logging), SQLite returns:

```
ERROR: SQLite3: cannot start a transaction within a transaction; [BEGIN] (1)
ERROR: SQL query "BEGIN" failed: SQL logic error (SQLITE_ERROR)
WARNING: Starting first transaction failed during ARP parsing
```

In FTL v6.6.2 this error was not handled gracefully. Normally it failed quietly and recovered within seconds. However, when Kubernetes CronJobs all fired at `:00`, the node simultaneously created multiple `veth` interfaces for new pods. This triggered a burst of ARP table updates - the ARP-parsing thread was invoked repeatedly in rapid succession, each attempt failing and retrying, creating a thundering-herd effect on SQLite. The database locked completely, blocking all DNS query logging writes, which caused FTL to stall and stop answering DNS queries for ~4 minutes until the backlog cleared.

### Why did fallback to 1.1.1.1 not help?

`/etc/resolv.conf` had both `127.0.0.1` (Pi-hole) and `1.1.1.1` listed. When Pi-hole went silent, the system correctly fell back to `1.1.1.1` - but `1.1.1.1` has no records for `.homelab.local`, so all internal DNS returned `NXDOMAIN` instead of resolving.

---

## 5 Whys

1. **Why did all homelab services fail simultaneously?** → Pi-hole stopped answering DNS queries for ~4 minutes
2. **Why did Pi-hole stop answering?** → FTL's SQLite database deadlocked during ARP parsing
3. **Why did SQLite deadlock?** → ARP-parsing thread tried `BEGIN` during an existing transaction; FTL v6.6.2 didn't handle this gracefully, and a concurrent burst of ARP updates from CronJob pod starts made it unrecoverable for several minutes
4. **Why did multiple CronJobs start simultaneously?** → All CronJobs were scheduled at `:00` (on the hour), creating simultaneous pod spawns and veth interface creation
5. **Why wasn't this caught earlier?** → The SQLite error appeared in FTL.log every hour but wasn't alerting on; the failure was intermittent and recovered within minutes; no alert existed for "DNS resolution failing for internal names"

---

## What Went Well

- Uptime Kuma detected the outage immediately and sent Telegram alerts within seconds
- FTL.log contained clear, timestamped errors that led directly to root cause
- The fix (pihole -up) was available upstream and took under 2 minutes to apply
- Recovery was automatic - no manual restart of Pi-hole was needed after each event

## What Went Poorly

- SQLite errors in FTL.log were not alerted on - the bug was firing for days/weeks undetected
- All CronJobs scheduled at `:00` with no intentional staggering - an obvious single point of temporal congestion
- No DNS health check that specifically tests `.homelab.local` resolution (probes were HTTPS-based)
- `cert-manager` was excluded from chaos-monkey exclusions, meaning cert rotation pods could have been killed at the worst moment

---

## Action Items

| Action | Owner | Priority | Status |
|--------|-------|----------|--------|
| Update Pi-hole FTL to v6.7 | Dmitry | P0 | ✅ Done |
| Stagger CronJob schedules (iptv-influx-writer → 5,35; chaos-monkey → :02) | Dmitry | P0 | ✅ Done |
| Add `cert-manager` to chaos-monkey exclusion list | Dmitry | P1 | ✅ Done |
| Add Prometheus alert on Pi-hole `SQLITE_ERROR` log pattern | Dmitry | P1 | Pending |
| Add blackbox probe for internal DNS (test `.homelab.local` resolution) | Dmitry | P1 | Pending |
| Document split-DNS architecture in homelab README | Dmitry | P2 | Pending |

---

## Lessons Learned

**Temporal coupling is a real failure mode.** All CronJobs at `:00` looked fine individually but created a system-level thundering herd. Stagger schedules by default.

**Silent errors in logs that fire repeatedly are pre-incident signals.** The SQLite error was there for days. An alert like `count_over_time({filename="/var/log/pihole/FTL.log"} |= "SQLITE_ERROR"[5m]) > 3` would have surfaced this before it cascaded.

**Fallback DNS that returns NXDOMAIN for internal names is worse than no fallback.** `1.1.1.1` as a fallback gave false confidence in the resolv.conf setup. For split-horizon DNS, internal and external resolvers need to be treated differently - or the fallback should be another internal resolver (e.g., a secondary Pi-hole instance).

---

## Related Files Changed

| File | Change |
|------|--------|
| `~/homelab-k3s/charts/chaos-monkey/values.yaml` | schedule `0→2 * * * *`; added `cert-manager` to excludeNamespaces |
| `~/homelab-k3s/apps/iptv/cronjobs.yaml` | iptv-influx-writer schedule `*/30→5,35 * * * *` |
| `/etc/pihole/custom.list` | Removed broken `address=/grafana.sre.dstepanov.dev/...` entry |
| `/home/bibigon88/homelab-observability/alerting/slo-rules.yml` | Fixed `slo:cronjob:success_ratio_7d` to use `increase(...[7d])` |

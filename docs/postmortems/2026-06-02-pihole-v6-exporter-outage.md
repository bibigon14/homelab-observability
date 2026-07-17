# Postmortem: Pi-hole Grafana dashboard showing "No data" after v5 → v6 upgrade

- **Status:** Resolved
- **Severity:** Low (home monitoring only - no user-facing impact)
- **Duration:** Unknown start time (silent failure) → ~2 hours active investigation
- **Author:** homelab SRE

## Summary

Pi-hole was upgraded in-place from v5 to v6.4.2 (FTL v6.6.2). At some
point after the upgrade, the "Pi-hole Monitor" Grafana dashboard started
showing "No data" on all panels. The existing exporter
(`eko/pihole-exporter`, a v5-compatible binary) had stopped working
because it authenticated against an API that no longer existed in the
form it expected. There was no alert for this - the exporter process was
still "running" (no crash, no restart loop), it just stopped successfully
collecting any metrics.

## Impact

- Loss of Pi-hole query/blocking visibility in Grafana for an unknown
  period (likely since the v6 upgrade).
- No alerting impact - the only signal was a human noticing "No data" on
  a dashboard during unrelated work.

## Timeline (relative)

- **T-?**: Pi-hole upgraded from v5 to v6.4.2 as part of routine `pihole
  -up`. No immediate symptoms - the old exporter binary kept running.
- **T+0**: While reviewing dashboards for an unrelated reason, the
  "Pi-hole Monitor" dashboard is noticed showing "No data" across all
  panels.
- **T+5m**: Initial hypothesis - wrong Grafana datasource. Checked
  Grafana's default datasource and found it had been set to InfluxDB
  (likely when a second datasource was added for an unrelated project),
  shadowing Prometheus as the implicit default for new panels. **This was
  a real secondary issue but not the root cause** - explicitly-configured
  panels still queried Prometheus and still showed no data.
- **T+15m**: Confirmed `pihole version` → Core v6.4.2 / Web v6.5 / FTL
  v6.6.2. The installed exporter (`/usr/local/bin/pihole-exporter`, last
  modified ~10 months prior) predates this and targets the v5 API.
- **T+30m**: Found an existing exporter repo checkout
  (`~/pihole6_exporter/`) already cloned from a v6-compatible exporter
  project, with a systemd unit already partially configured but failing:

  ```
  Active: failed (Result: exit-code)
  Process: ExecStart=/usr/local/bin/pihole6_exporter -H localhost -k $PIHOLE_PASSWORD (code=exited, status=1)
  ```

  The `$PIHOLE_PASSWORD` in `ExecStart=` was a literal unexpanded string -
  systemd does not perform shell-style variable expansion in `ExecStart=`.
  `EnvironmentFile=` makes the variable available to the *process*, not
  to the unit file's command line.
- **T+45m**: Fixed by moving the variable substitution responsibility:
  `EnvironmentFile=/etc/pihole6_exporter.env` sets `PIHOLE_PASSWORD` in the
  process environment, and the exporter binary itself reads it from
  `os.environ` rather than expecting it as a literal CLI argument from
  systemd.
- **T+50m**: Exporter starts (`active (running)`), logs `scrape
  completed`. Grafana panel "Queries by Type" populates within ~1 minute.
  Other panels (totals, block percentage) remain at zero.
- **T+60m**: Root-caused the remaining zeroed metrics: the v6
  `/api/stats/query_types` endpoint returns
  `{"types": {"A": n, "AAAA": n, ...}}` - a dict - whereas the exporter
  code (ported from v5 assumptions) iterated over it expecting a list of
  `{"name": ..., "count": ...}` objects. This didn't error (Python
  iterating a dict yields its keys, which then failed a different lookup
  silently inside a `try/except`), it just produced zero for every
  metric except the one endpoint whose shape happened to still match.
- **T+90m**: Fixed the response parsing for the dict shape. All panels
  populate after Prometheus's next scrape interval.

## Root cause

Two independent issues, both triggered by the same upgrade:

1. **API breaking change, no compatibility shim**: Pi-hole v6 replaced
   static-token auth (`?auth=<token>`) with session-based auth (`POST
   /api/auth` → `sid` → `X-FTL-SID` header), and changed several response
   shapes (notably `query_types` from list to dict). The v5 exporter
   didn't error loudly on this - it degraded to reporting nothing,
   indistinguishable at a glance from "no traffic."

2. **No detection for "exporter running but reporting nothing"**: the
   exporter process itself never crashed or restarted, so
   process-level health checks (`systemctl is-active`) reported healthy
   throughout. The only signal was a Grafana panel showing "No data,"
   which nobody was watching proactively.

## What went well

- The fix was self-contained once identified - no data was lost (Pi-hole
  itself kept logging normally; only the *exported* metrics were
  affected).
- A v6-compatible exporter project was already half-staged from a
  previous attempt, which shortened the fix significantly.

## What went poorly

- **Silent degradation**: an exporter that authenticates successfully but
  parses responses incorrectly should fail loudly (non-zero exit, error
  log, or a Prometheus `up{job="pihole6"}` style staleness/absent()
  alert) - not quietly report zeros.
- **No alert on "metric absent for too long"** for any of the homelab's
  exporters. A dashboard showing "No data" is a *passive* signal that
  depends on a human looking at the right dashboard at the right time.
- **systemd `ExecStart=` + shell variable confusion**: this is a common
  enough footgun that it's worth calling out explicitly - variables in
  `ExecStart=` are NOT expanded by a shell. Either read secrets from the
  environment inside the program (preferred), or use
  `ExecStart=/bin/sh -c '... $VAR ...'` if you must use shell expansion.

## Follow-ups

- [x] Rewrite `query_types` parsing for the v6 dict shape (this repo:
      `exporters/pihole6/pihole6_exporter.py`)
- [x] Document the `EnvironmentFile=` + `ExecStart=` interaction
      (this repo: `exporters/pihole6/README.md`)
- [ ] Add a Prometheus alerting rule:
      `absent_over_time(pihole_dns_queries_total[15m])` → page/notify.
      Currently only IPTV/network monitoring has Telegram alerting; this
      should be extended to all homelab exporters generically (e.g. a
      single `up == 0` / staleness rule per job, rather than per-metric).
- [ ] Audit Grafana default datasource - confirm Prometheus, not
      InfluxDB, is default, and consider not relying on "default
      datasource" at all (explicitly set datasource per panel/dashboard,
      which was already the case here but worth re-confirming after every
      new datasource addition).
- [ ] Pin exporter version/commit in a way that survives `git pull`
      surprises - the "already up to date" `git pull` during this
      incident initially gave false confidence that the exporter code was
      current, when the real issue was the systemd unit configuration,
      not the code.

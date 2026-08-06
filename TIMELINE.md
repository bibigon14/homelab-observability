# Timeline

A rough history of how a $228 starter kit turned into... whatever this is.

- **2026-05-26** - Raspberry Pi 5 (8GB) Starter Kit arrives. The plan was modest: Pi-hole, maybe a Homebridge instance.
- **2026-05-28** - Raspberry Pi M.2 HAT+ and a 512GB NVMe SSD arrive. The 14TB Seagate HDD wasn't going to cut it for everything that followed.
- **2026-05-28 to 2026-05-29** - WireGuard VPN set up with DuckDNS. IPTV server monitoring begins as a handful of cron scripts (`analyze.py`, `auto_switch.py`).
- **Early June 2026** - Grafana + Prometheus + InfluxDB stack stood up. Garage workshop also gets organized around this time (unrelated to the Pi, but suspiciously parallel in spirit).
- **2026-06-14 to 2026-06-15** - `wc2026-telegram-bot` gets Redis caching, Dockerized, rate-limited. `homelab-observability` published - textfile exporters, a Pi-hole v5→v6 postmortem, alerting rules.
- **2026-06-17** - The big one: `alertmanager-telegram-bridge` built from scratch. k3s installed. Everything - `wc2026bot`, `redis`, the bridge, and all three IPTV cron jobs - migrated off Docker Compose and host crontab onto Kubernetes. State migrated to Redis where it made sense. `homelab-k3s` published.

Started as "I'll just block some ads." Escalated quickly.

## Hardware

- Raspberry Pi 5 (8GB), Raspberry Pi OS Lite 64-bit
- 14TB Seagate HDD (migrated over from a router that was doing too much)
- The usual collection of cables you don't remember buying

## Why document this at all

Mostly for future-me, who will absolutely forget why a particular CronJob has a `timeZone` field or why one service insists on `--network host`. Partly because a working homelab with real incidents, real postmortems, and a real migration story is a more honest signal of SRE skill than another todo-app tutorial.

## 2026-08-05 — Thanos compact triple-incident + auto-remediate

Two distinct Thanos-internal `checksum mismatch` failure modes surfaced
within 16 hours on `homebridge`. Investigation confirmed both are
long-standing upstream bugs (issues #5944, #6194, #5917, #8611), not
local corruption: R2 returns byte-stable sha256 on repeat reads, `thanos
tools bucket verify` reports the affected blocks clean, no dmesg/EDAC
events, peak memory 735MB out of 8GB. Wrote a blameless postmortem, an
operational runbook, and deployed a systemd-based auto-remediate so the
pattern doesn't require a human next time.

See: `docs/postmortems/2026-08-05-thanos-compact-checksum-cascade.md`

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

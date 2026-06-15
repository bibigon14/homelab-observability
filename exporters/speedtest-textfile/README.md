# speedtest-textfile

Periodically runs the Ookla `speedtest` CLI and exposes download/upload
bandwidth, ping, and jitter to Prometheus via the textfile collector.

## The two gotchas that ate an afternoon

**1. Run it as a normal user, not a service account.**
Ookla's backend returned HTTP 403 specifically to requests made by the
`prometheus` system user on this host, while the identical binary worked
fine as a regular interactive user with the same network path. The fix
was simply: don't run this from `prometheus`'s crontab — run it from your
own user's crontab and have node_exporter read the resulting file (the
textfile directory just needs to be writable by that user).

**2. Use the full path to the binary in cron.**
`cron`'s `PATH` is typically `/usr/bin:/bin`, which doesn't include
`~/.local/bin` — a common install location for `speedtest`. A script that
works perfectly when you run it manually can silently fail (or run a
*different*, system-wide `speedtest` with different behavior) under cron.
Always `which speedtest` as the user that will run the cron job, and hardcode
that path (or pass it via `SPEEDTEST_BIN`).

## Setup

```bash
sudo cp speedtest_exporter.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/speedtest_exporter.sh

# Make sure the textfile directory is writable by your user
sudo chmod 775 /var/lib/prometheus/node-exporter
sudo chgrp youruser /var/lib/prometheus/node-exporter
```

Add to **your user's** crontab (`crontab -e`, not `sudo crontab -e`):

```cron
55 * * * * SPEEDTEST_BIN=/home/youruser/.local/bin/speedtest /usr/local/bin/speedtest_exporter.sh >> /home/youruser/speedtest.log 2>&1
```

## Output

```
speedtest_download_bits_per_second{server_id="12345",server_name="Example ISP"} 1.95e+09
speedtest_upload_bits_per_second{server_id="12345",server_name="Example ISP"} 1.92e+09
speedtest_ping_latency_ms{server_id="12345",server_name="Example ISP"} 7.8
speedtest_jitter_ms{server_id="12345",server_name="Example ISP"} 0.6
```

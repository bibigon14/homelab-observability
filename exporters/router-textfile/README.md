# router-textfile

Collects temperature, memory, and per-core CPU usage from a router (or any
SSH-reachable Linux device with `/proc`) and exposes them to Prometheus via
`node_exporter`'s textfile collector.

## Why this approach

Most consumer routers can't run `node_exporter` directly — no package
manager, limited flash storage, vendor firmware that doesn't want extra
daemons. But they have SSH and `/proc`. This script does the minimum:

- SSH in, read `/sys/class/thermal/thermal_zone0/temp` and `/proc/meminfo`
- Read `/proc/stat` twice, one second apart, and compute per-core CPU usage
  from the delta (the standard technique — instantaneous CPU% isn't
  meaningful from a single `/proc/stat` snapshot)
- Write everything in Prometheus exposition format to a `.prom` file

`node_exporter` picks up any `.prom` files in its textfile directory on
every scrape.

## Setup

1. Generate a dedicated SSH key for this purpose and add the public key to
   the router's authorized keys (most consumer routers support this via
   their admin UI or `/jffs` on Asus/Merlin firmware).

2. Copy the script and make it executable:

   ```bash
   sudo cp router_metrics.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/router_metrics.sh
   ```

3. Configure via environment variables (or edit the defaults at the top of
   the script):

   ```bash
   export ROUTER_HOST=192.168.1.1
   export ROUTER_USER=admin
   export ROUTER_PORT=22
   export SSH_KEY=/home/youruser/.ssh/router_key
   export CPU_CORES=4
   export OUTPUT_FILE=/var/lib/prometheus/node-exporter/router_metrics.prom
   ```

4. Test it manually:

   ```bash
   sudo /usr/local/bin/router_metrics.sh
   cat /var/lib/prometheus/node-exporter/router_metrics.prom
   ```

5. Schedule via cron (every minute is fine — the script itself takes ~1s
   due to the two `/proc/stat` samples):

   ```cron
   * * * * * ROUTER_HOST=192.168.1.1 SSH_KEY=/home/youruser/.ssh/router_key /usr/local/bin/router_metrics.sh
   ```

## Output

```
router_temperature_celsius 61.90
router_memory_total_bytes 2097254400
router_memory_free_bytes 796184576
router_memory_available_bytes 1302716416
router_cpu_usage_percent{core="cpu0"} 1.00
router_cpu_usage_percent{core="cpu1"} 11.00
router_cpu_usage_percent{core="cpu2"} 3.00
router_cpu_usage_percent{core="cpu3"} 4.00
```

## Notes

- The script writes to `${OUTPUT_FILE}.tmp` and then `mv`s it into place,
  so `node_exporter` never reads a partially-written file mid-scrape.
- Set thresholds in Grafana around 60°C (warning) and 75°C (critical) for
  `router_temperature_celsius` — consumer router SoCs typically throttle
  or become unstable above 75-80°C.

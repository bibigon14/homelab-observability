import sys, os

pid_str = sys.argv[1] if len(sys.argv) > 1 else '0'
try:
    pid = int(pid_str)
except ValueError:
    pid = 0

lines = [
    "# HELP riverbot_process_up RiverBot process running (1=up, 0=down)",
    "# TYPE riverbot_process_up gauge",
]

if pid <= 0 or not os.path.exists(f"/proc/{pid}"):
    lines.append("riverbot_process_up 0")
else:
    lines.append("riverbot_process_up 1")
    try:
        status = open(f"/proc/{pid}/status").read()
        rss = next((int(l.split()[1]) for l in status.splitlines() if l.startswith("VmRSS")), 0)
        vms = next((int(l.split()[1]) for l in status.splitlines() if l.startswith("VmSize")), 0)
        lines += [
            "# HELP riverbot_process_memory_rss_bytes RSS memory in bytes",
            "# TYPE riverbot_process_memory_rss_bytes gauge",
            f"riverbot_process_memory_rss_bytes {rss * 1024}",
            "# HELP riverbot_process_memory_virtual_bytes Virtual memory in bytes",
            "# TYPE riverbot_process_memory_virtual_bytes gauge",
            f"riverbot_process_memory_virtual_bytes {vms * 1024}",
        ]
    except Exception: pass
    try:
        stat = open(f"/proc/{pid}/stat").read().split()
        clk = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
        utime = int(stat[13]) / clk
        stime = int(stat[14]) / clk
        lines += [
            "# HELP riverbot_process_cpu_user_seconds_total User CPU time (seconds)",
            "# TYPE riverbot_process_cpu_user_seconds_total counter",
            f"riverbot_process_cpu_user_seconds_total {utime:.3f}",
            "# HELP riverbot_process_cpu_system_seconds_total System CPU time (seconds)",
            "# TYPE riverbot_process_cpu_system_seconds_total counter",
            f"riverbot_process_cpu_system_seconds_total {stime:.3f}",
        ]
    except Exception: pass

print("\n".join(lines))

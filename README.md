# server-performance-stats

Lightweight shell script to report basic server performance statistics.

Features
- Total CPU usage
- Total memory usage (Used vs Free + percentage)
- Total disk usage (Used vs Free + percentage)
- Top 5 processes by CPU usage
- Top 5 processes by memory usage

The script is Linux-first (reads /proc) but includes fallbacks for macOS (Darwin). It aims to be dependency-light and usable on most servers.


Requirements
- POSIX-compatible shell (bash recommended)
- Common system utilities: `ps`, `df`, `awk`, `sed`, `top`, `vm_stat` (macOS), `sysctl` (macOS)
- `numfmt` (optional) improves human-readable memory/disk formatting; the script falls back to simple units if `numfmt` is missing.

Quick start

1. Make the script executable:

```bash
chmod +x server-stats.sh
```

2. Run it:

```bash
./server-stats.sh
```

Example output (trimmed):

```
========== Server Performance Summary (OS: Linux) ==========
Total CPU usage: 7.2%

========== Memory ==========
Total: 15.56 GiB
Used:  3.12 GiB (20.0%)
Free:  12.44 GiB

========== Disk (aggregated/primary) ==========
Total: 250.00 GiB
Used:  30.50 GiB (12%)
Free:  219.50 GiB

========== Top 5 processes by CPU ==========
PID  %CPU %MEM USER  COMM
... (top 5 rows) ...
```

Running regularly (cron)

To run every 5 minutes and append output to a log:
```bash
# edit root or your user's crontab: crontab -e
*/5 * * * * /path/to/server-stats.sh >> /var/log/server-stats.log 2>&1
```

Notes and troubleshooting
- Linux systems: the script reads `/proc/stat` and `/proc/meminfo` for accurate CPU and memory metrics.
- macOS: the script parses `top`, `vm_stat`, and `sysctl`. macOS `top` output formats can vary across versions and locales — if CPU% appears incorrect on macOS, inspect `top -l 2 -s 0.5 | grep "CPU usage"` to see how your system prints CPU usage.
- Containers/minimal images: some minimal containers may lack `ps`, `df`, or `/proc` entries; the script will print `N/A` or fall back to available tools when that happens.

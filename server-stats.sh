#!/usr/bin/env bash
set -euo pipefail

# server-stats.sh - lightweight Linux server stats reporter
# Outputs: Total CPU usage, Memory used vs free, Disk used vs free, Top 5 processes by CPU, Top 5 by memory
# Designed primarily for Linux but includes fallbacks for macOS (Darwin) so it's safe to run on macOS too.

OS=$(uname -s)

print_header() {
  printf "\n========== %s ==========\n" "$1"
}

separator() {
  printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' -
}

human_readable_bytes() {
  # takes bytes as input and prints a human-readable string like "1.23 GiB"
  awk 'function hr(x){split("B KiB MiB GiB TiB PiB",u); i=1; while(x>=1024 && i<6){x/=1024;i++} printf "%.2f %s", x, u[i]} {hr($1)}' <<<"$1"
}

# 1) CPU usage
get_cpu_usage_linux() {
  if [ -r /proc/stat ]; then
    # discard the first (label) and the trailing guest fields we don't use to avoid warnings
    read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat || return 1
    total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle1=$idle
    sleep 1
    read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat || return 1
    total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle2=$idle
    total=$((total2 - total1))
    idle_diff=$((idle2 - idle1))
    if [ "$total" -le 0 ]; then
      echo "0.0"
      return 0
    fi
    awk "BEGIN {printf \"%.1f\", (1 - $idle_diff / $total) * 100}"
  else
    # fallback to top if /proc/stat unexpectedly missing
    top -bn1 | awk -F'id,' 'NR==1{split($2, a, "%"); usage=100-a[1]; printf("%.1f", usage)}'
  fi
}

get_cpu_usage_darwin() {
  # Use top to sample CPU usage; parse the last CPU usage line
  cpu_line=$(top -l 2 -s 0.5 2>/dev/null | grep "CPU usage" | tail -n1 || true)
  if [ -n "$cpu_line" ]; then
    # extract user and sys percentages
    user_pct=$(sed -n 's/.* \([0-9]*\.?[0-9]*\)% user.*/\1/p' <<<"$cpu_line" || true)
    sys_pct=$(sed -n 's/.* \([0-9]*\.?[0-9]*\)% sys.*/\1/p' <<<"$cpu_line" || true)
    user_pct=${user_pct:-0}
    sys_pct=${sys_pct:-0}
    awk "BEGIN {printf \"%.1f\", ($user_pct + $sys_pct)}"
    return 0
  fi
  echo "0.0"
}

get_cpu_usage() {
  case "$OS" in
    Linux) get_cpu_usage_linux ;;
    Darwin) get_cpu_usage_darwin ;;
    *) get_cpu_usage_linux ;;
  esac
}

# 2) Memory usage
get_memory_info_linux() {
  if [ -r /proc/meminfo ]; then
    mem_total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    mem_available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo || true)
    if [ -z "$mem_available_kb" ]; then
      mem_free_kb=$(awk '/MemFree:/ {print $2}' /proc/meminfo)
      buffers_kb=$(awk '/Buffers:/ {print $2}' /proc/meminfo)
      cached_kb=$(awk '/^Cached:/ {print $2}' /proc/meminfo)
      mem_available_kb=$((mem_free_kb + buffers_kb + cached_kb))
    fi
    mem_used_kb=$((mem_total_kb - mem_available_kb))
    mem_used_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_used_kb / $mem_total_kb) * 100}")
    if command -v numfmt >/dev/null 2>&1; then
      mem_total_human=$(numfmt --to=iec --from=K "$mem_total_kb" 2>/dev/null || printf "%s KB" "$mem_total_kb")
      mem_used_human=$(numfmt --to=iec --from=K "$mem_used_kb" 2>/dev/null || printf "%s KB" "$mem_used_kb")
      mem_free_human=$(numfmt --to=iec --from=K "$mem_available_kb" 2>/dev/null || printf "%s KB" "$mem_available_kb")
    else
      mem_total_human=$(awk "BEGIN {printf \"%.2f MB\", $mem_total_kb/1024}")
      mem_used_human=$(awk "BEGIN {printf \"%.2f MB\", $mem_used_kb/1024}")
      mem_free_human=$(awk "BEGIN {printf \"%.2f MB\", $mem_available_kb/1024}")
    fi
    printf "%s|%s|%s|%s\n" "$mem_total_human" "$mem_used_human" "$mem_free_human" "$mem_used_pct"
  else
    echo "N/A|N/A|N/A|0.0"
  fi
}

get_memory_info_darwin() {
  # total bytes
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
  if [ "$total_bytes" -eq 0 ]; then
    echo "N/A|N/A|N/A|0.0"
    return
  fi
  # vm_stat report
  vm_output=$(vm_stat 2>/dev/null || true)
  free_pages=$(awk '/Pages free/ {gsub(/\.|\D/,"",$3); print $3}' <<<"$vm_output" || echo 0)
  spec_pages=$(awk '/Pages speculative/ {gsub(/\.|\D/,"",$3); print $3}' <<<"$vm_output" || echo 0)
  free_pages=${free_pages:-0}
  spec_pages=${spec_pages:-0}
  free_bytes=$(( (free_pages + spec_pages) * page_size ))
  used_bytes=$(( total_bytes - free_bytes ))
  mem_used_pct=$(awk "BEGIN {printf \"%.1f\", ($used_bytes / $total_bytes) * 100}")
  # human readable
  mem_total_human=$(human_readable_bytes "$total_bytes")
  mem_used_human=$(human_readable_bytes "$used_bytes")
  mem_free_human=$(human_readable_bytes "$free_bytes")
  printf "%s|%s|%s|%s\n" "$mem_total_human" "$mem_used_human" "$mem_free_human" "$mem_used_pct"
}

get_memory_info() {
  case "$OS" in
    Linux) get_memory_info_linux ;;
    Darwin) get_memory_info_darwin ;;
    *) get_memory_info_linux ;;
  esac
}

# 3) Disk usage
get_disk_info_linux() {
  if df --total >/dev/null 2>&1; then
    total_line=$(df -B1 --total -x tmpfs -x devtmpfs 2>/dev/null | awk 'END{print}')
    # discard filesystem label and mountpoint (unused)
    read -r _ size used avail usep _ <<<"$total_line" || true
    if [ -n "$size" ]; then
      if command -v numfmt >/dev/null 2>&1; then
        size_h=$(numfmt --to=iec --from=1 "$size" 2>/dev/null || printf "%s" "$size")
        used_h=$(numfmt --to=iec --from=1 "$used" 2>/dev/null || printf "%s" "$used")
        avail_h=$(numfmt --to=iec --from=1 "$avail" 2>/dev/null || printf "%s" "$avail")
      else
        size_h="$size"
        used_h="$used"
        avail_h="$avail"
      fi
      printf "%s|%s|%s|%s\n" "$size_h" "$used_h" "$avail_h" "$usep"
      return 0
    fi
  fi
  root_line=$(df -h / | awk 'NR==2{print $2"|"$3"|"$4"|"$5}')
  if [ -n "$root_line" ]; then
    echo "$root_line"
  else
    echo "N/A|N/A|N/A|0%"
  fi
}

get_disk_info_darwin() {
  # macOS: use df -k for root filesystem as a sensible fallback
  root_line=$(df -k / | awk 'NR==2{print $2"|"$3"|"$4"|"$5}')
  if [ -n "$root_line" ]; then
    # convert sizes (in KB) to human readable
    IFS='|' read -r total_k used_k avail_k used_pct <<<"$root_line"
    total_bytes=$((total_k * 1024))
    used_bytes=$((used_k * 1024))
    avail_bytes=$((avail_k * 1024))
    printf "%s|%s|%s|%s\n" "$(human_readable_bytes $total_bytes)" "$(human_readable_bytes $used_bytes)" "$(human_readable_bytes $avail_bytes)" "$used_pct"
  else
    echo "N/A|N/A|N/A|0%"
  fi
}

get_disk_info() {
  case "$OS" in
    Linux) get_disk_info_linux ;;
    Darwin) get_disk_info_darwin ;;
    *) get_disk_info_linux ;;
  esac
}

# 4) Top processes
get_top_processes_linux() {
  ps -eo pid,pcpu,pmem,user,comm --sort=-pcpu | awk 'NR==1{print; next} NR>1 && NR<=6{print}'
}
get_top_processes_darwin() {
  # BSD-style ps flags
  ps -axo pid,pcpu,pmem,user,comm | awk 'NR==1{print; next} NR>1 && NR<=6{print}'
}

get_top_mem_processes_linux() {
  ps -eo pid,pcpu,pmem,user,comm --sort=-pmem | awk 'NR==1{print; next} NR>1 && NR<=6{print}'
}
get_top_mem_processes_darwin() {
  ps -axo pid,pcpu,pmem,user,comm | awk 'NR==1{print; next} NR>1 && NR<=6{print}'
}

get_top_processes() {
  case "$OS" in
    Linux) get_top_processes_linux ;;
    Darwin) get_top_processes_darwin ;;
    *) get_top_processes_linux ;;
  esac
}
get_top_mem_processes() {
  case "$OS" in
    Linux) get_top_mem_processes_linux ;;
    Darwin) get_top_mem_processes_darwin ;;
    *) get_top_mem_processes_linux ;;
  esac
}

# Main output
print_header "Server Performance Summary (OS: $OS)"

# CPU
cpu_usage=$(get_cpu_usage || echo "0.0")
printf "Total CPU usage: %s%%\n" "$cpu_usage"
separator

# Memory
print_header "Memory"
mem_info=$(get_memory_info)
IFS='|' read -r mem_total_h mem_used_h mem_free_h mem_used_pct <<<"$mem_info"
printf "Total: %s\nUsed:  %s (%s%%)\nFree:  %s\n" "$mem_total_h" "$mem_used_h" "$mem_used_pct" "$mem_free_h"
separator

# Disk
print_header "Disk (aggregated/primary)"
disk_info=$(get_disk_info)
IFS='|' read -r disk_total_h disk_used_h disk_free_h disk_used_pct <<<"$disk_info"
printf "Total: %s\nUsed:  %s (%s)\nFree:  %s\n" "$disk_total_h" "$disk_used_h" "$disk_used_pct" "$disk_free_h"
separator

# Top processes by CPU
print_header "Top 5 processes by CPU"
get_top_processes
separator

# Top processes by Memory
print_header "Top 5 processes by Memory"
get_top_mem_processes

utc_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
local_iso="$(date +"%Y-%m-%dT%H:%M:%S %z (%Z)" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S %Z")"
printf "\nReport generated at (same instant):\n  UTC:   %s\n  local: %s\n\n" "$utc_iso" "$local_iso"

exit 0


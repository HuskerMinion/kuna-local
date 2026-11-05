#!/bin/bash
# kuna-healthlog.sh - sample the camera's health from an always-on LAN host (a Pi with
# some headroom) on an interval and append one CSV row per sample. This is how we CATCH
# the next offline incident: the camera's own kernel log is overwritten within seconds by
# OSD debug spam and it has no syslogd, so on-device logs are useless after the fact.
#
# It records whether the box is reachable, and when SSH fails it still pings, so we can
# tell "SSH starved under load" (ping OK, ssh fail) from "fully offline" (both fail).
#
# Setup on the logging host:
#   1. Put the camera's root SSH key here (chmod 600), set KEY below.
#   2. Set CAM to the camera's LAN IP.
#   3. Run under systemd, or:  nohup ./kuna-healthlog.sh >/dev/null 2>&1 &
#      (or cron @reboot). Default interval 60s.
#
# Columns: iso_time,reachable,ping_ms,uptime_s,load1,memfree_kb,strm_rss_kb,threads,conns554,wifi_dbm
# reachable: ssh=both OK, pingonly=ping OK/ssh starved-or-down, down=no ping

CAM="${CAM:-CAMERA_IP}"
KEY="${KEY:-$HOME/.ssh/kuna_root_ecdsa}"
INTERVAL="${INTERVAL:-60}"
LOG="${LOG:-$HOME/kuna-health.csv}"
MAX_ROWS="${MAX_ROWS:-20160}"   # cap on data rows (~14 days at 60s); header is always kept.
                                # Oldest rows are dropped first, so the file never grows unbounded
                                # while still holding plenty of history to inspect an incident.

SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes root@$CAM"

# remote one-liner: print the metrics as space-separated fields
REMOTE='
u=$(cut -d. -f1 /proc/uptime)
l=$(cut -d" " -f1 /proc/loadavg)
mf=$(awk "/^MemFree:/{print \$2}" /proc/meminfo)
p=$(pidof strm_svc 2>/dev/null)
rss=$(grep VmRSS /proc/$p/status 2>/dev/null | awk "{print \$2}")
th=$(ls /proc/$p/task 2>/dev/null | wc -l)
c=$(netstat -tn 2>/dev/null | grep -c ":554 ")
dbm=$(iwconfig wlan0 2>/dev/null | sed -n "s/.*Signal level=\(-\?[0-9]*\).*/\1/p")
echo "$u ${l:-NA} ${mf:-NA} ${rss:-NA} ${th:-NA} ${c:-NA} ${dbm:-NA}"
'

[ -f "$LOG" ] || echo "iso_time,reachable,ping_ms,uptime_s,load1,memfree_kb,strm_rss_kb,threads,conns554,wifi_dbm" > "$LOG"

echo "$(date '+%F %T') healthlog start cam=$CAM interval=${INTERVAL}s max_rows=$MAX_ROWS -> $LOG"
n=0
while true; do
  ts=$(date -u '+%FT%TZ')
  # ping (portable-ish: Linux ping)
  pms=$(ping -c1 -W2 "$CAM" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
  # Hard timeout around ssh: ConnectTimeout only covers connect, not a post-connect stall
  # (the RT-starved camera can accept the TCP then hang), which would otherwise wedge the loop.
  if out=$(timeout 15 $SSH "$REMOTE" 2>/dev/null) && [ -n "$out" ]; then
    set -- $out
    echo "$ts,ssh,${pms:-NA},$1,$2,$3,$4,$5,$6,$7" >> "$LOG"
  elif [ -n "$pms" ]; then
    echo "$ts,pingonly,$pms,NA,NA,NA,NA,NA,NA,NA" >> "$LOG"
  else
    echo "$ts,down,NA,NA,NA,NA,NA,NA,NA,NA" >> "$LOG"
  fi

  # cap size: every ~60 samples, trim to header + last MAX_ROWS data rows (oldest dropped)
  n=$((n+1))
  if [ $((n % 60)) -eq 0 ] && [ -f "$LOG" ]; then
    total=$(wc -l < "$LOG")
    if [ "$total" -gt $((MAX_ROWS + 1)) ]; then
      { head -n1 "$LOG"; tail -n "$MAX_ROWS" "$LOG"; } > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
  fi

  sleep "$INTERVAL"
done

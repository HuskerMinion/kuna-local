#!/bin/ash
# kuna-watchdog.sh - on-camera safety net. NEVER reboots the unit.
#
# Replaces the two useful things the stock `kunabeat` watchdog did (Wi-Fi recovery)
# WITHOUT its fatal habit of rebooting the whole camera on a loop. Adds a memory guard
# for the slow strm_svc RSS creep that can OOM this 128 MB, swapless board after hours.
#
# Background (see device/setup/cloud-cut.md "Camera drops offline"):
#   - strm_svc (the RTSP server) runs at REAL-TIME priority. When a client pulls both
#     stream1 + stream2 continuously (e.g. a 24/7 NVR), the single-core A5s sits at
#     load ~5 and strm_svc starves sshd / wpa_supplicant of CPU -> SSH times out, the
#     Wi-Fi link can drop, and over hours the box wedges. Ping may still answer.
#   - strm_svc is supervised by `kunamonitor`, so killing it is safe: it is respawned
#     automatically (which also resets its RSS). That is what the memory guard relies on.
#
# This watchdog does two things, each independently toggleable:
#   1. LINK HEAL  - if the default gateway is unreachable for several checks, bounce
#                   Wi-Fi via nmcli (down/up the connection). No reboot.
#   2. MEM GUARD  - if MemFree drops below MIN_FREE_KB or strm_svc RSS exceeds
#                   MAX_STRM_RSS_KB, kill strm_svc so kunamonitor respawns it fresh.
#
# Install:  /opt/kuna/ha/kuna-watchdog.sh  (chmod +x), started from the boot path the
#           same way bridge.sh is (append a start line to kunanetrules.ash), e.g.:
#               /opt/kuna/ha/kuna-watchdog.sh >/dev/null 2>&1 &
# Disable at runtime:  touch /opt/kuna/ha/watchdog.off
# Log (ring, on tmpfs to spare flash):  /tmp/kuna-watchdog.log

### ---- config ---------------------------------------------------------------
GW="GATEWAY_IP"                 # default gateway to probe for link health (set this)
WIFI_CON="YOUR_WIFI"            # nmcli connection name (nmcli -t -f NAME con show)
WIFI_DEV="wlan0"

ENABLE_LINK_HEAL=1              # bounce Wi-Fi when gateway unreachable
ENABLE_MEM_GUARD=1             # restart strm_svc under memory pressure

CHECK_EVERY=30                 # seconds between checks
FAIL_BEFORE_HEAL=4             # consecutive failed gateway probes before bouncing Wi-Fi
HEAL_COOLDOWN=180              # min seconds between Wi-Fi bounces
MIN_FREE_KB=16000              # restart strm_svc if MemFree falls below this
MAX_STRM_RSS_KB=70000          # restart strm_svc if its RSS grows past this
STRM_COOLDOWN=600              # min seconds between strm_svc restarts

OFF_FLAG=/opt/kuna/ha/watchdog.off
LOG=/tmp/kuna-watchdog.log
LOG_MAX=2000                   # keep the log to the last N lines
### ---------------------------------------------------------------------------

log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
  # trim the ring
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
    tail -n $((LOG_MAX/2)) "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

now() { cut -d. -f1 /proc/uptime; }

strm_rss_kb() {
  p=$(pidof strm_svc 2>/dev/null) || return 1
  [ -n "$p" ] || return 1
  grep VmRSS /proc/"$p"/status 2>/dev/null | awk '{print $2}'
}

mem_free_kb() { awk '/^MemFree:/{print $2}' /proc/meminfo; }

restart_strm() {
  p=$(pidof strm_svc 2>/dev/null)
  [ -n "$p" ] || { log "mem-guard: strm_svc not running, nothing to restart"; return; }
  log "mem-guard: killing strm_svc (pid $p) so kunamonitor respawns it [$1]"
  kill "$p" 2>/dev/null
  sleep 3
  kill -9 "$p" 2>/dev/null   # if it ignored SIGTERM
}

bounce_wifi() {
  log "link-heal: gateway $GW unreachable -> bouncing Wi-Fi ($WIFI_CON/$WIFI_DEV)"
  nmcli con down "$WIFI_CON" >/dev/null 2>&1
  sleep 2
  nmcli con up "$WIFI_CON" >/dev/null 2>&1 \
    || { nmcli radio wifi off >/dev/null 2>&1; sleep 2; nmcli radio wifi on >/dev/null 2>&1; }
}

log "watchdog start (link_heal=$ENABLE_LINK_HEAL mem_guard=$ENABLE_MEM_GUARD gw=$GW con=$WIFI_CON)"
fails=0
last_heal=0
last_strm=0

while true; do
  [ -f "$OFF_FLAG" ] && { sleep "$CHECK_EVERY"; continue; }
  t=$(now)

  # 1. LINK HEAL ------------------------------------------------------------
  if [ "$ENABLE_LINK_HEAL" = "1" ]; then
    if ping -c1 -W3 "$GW" >/dev/null 2>&1; then
      fails=0
    else
      fails=$((fails+1))
      if [ "$fails" -ge "$FAIL_BEFORE_HEAL" ] && [ $((t - last_heal)) -ge "$HEAL_COOLDOWN" ]; then
        bounce_wifi
        last_heal=$t
        fails=0
      fi
    fi
  fi

  # 2. MEM GUARD ------------------------------------------------------------
  if [ "$ENABLE_MEM_GUARD" = "1" ] && [ $((t - last_strm)) -ge "$STRM_COOLDOWN" ]; then
    mf=$(mem_free_kb); rss=$(strm_rss_kb)
    if [ -n "$mf" ] && [ "$mf" -lt "$MIN_FREE_KB" ]; then
      restart_strm "MemFree=${mf}kB < ${MIN_FREE_KB}kB"
      last_strm=$t
    elif [ -n "$rss" ] && [ "$rss" -gt "$MAX_STRM_RSS_KB" ]; then
      restart_strm "strm_svc RSS=${rss}kB > ${MAX_STRM_RSS_KB}kB"
      last_strm=$t
    fi
  fi

  sleep "$CHECK_EVERY"
done

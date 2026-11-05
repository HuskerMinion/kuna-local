#!/bin/ash
# kuna-watchdog.sh (v3) - keep the Wi-Fi stack scheduled ABOVE strm_svc. NEVER reboots.
#
# Root cause of the offline flaps: this is a single-core box, and strm_svc runs at
# SCHED_RR priority 10 while wpa_supplicant ships at SCHED_RR priority 1 and NetworkManager
# at SCHED_OTHER. Under streaming load strm_svc starves the Wi-Fi stack, the association
# drops, and the camera goes offline. This watchdog continuously ensures wpa_supplicant and
# NetworkManager are scheduled ABOVE strm_svc so the link survives load.
#
# v3 CHANGES: REMOVED link-heal (it bounced healthy Wi-Fi via an unreliable gateway-ping test,
# which made outages worse). Kept a (relaxed) memory guard. Added the RT-priority keeper.
#
# Install: /opt/kuna/ha/kuna-watchdog.sh (chmod +x), autostart from kunanetrules.ash.
# Disable: touch /opt/kuna/ha/watchdog.off     Log: /opt/kuna/ha/kuna-watchdog.log

### ---- config ---------------------------------------------------------------
ENABLE_PRIO=1                  # keep wpa_supplicant/NetworkManager above strm_svc
WIFI_PRIO=30                   # SCHED_RR priority for wpa_supplicant (strm_svc is 10)
NM_PRIO=20                     # SCHED_RR priority for NetworkManager

ENABLE_MEM_GUARD=1             # restart amba stack only under genuine memory pressure
MIN_FREE_KB=8000               # MemFree floor (idle dips to ~9-20MB, so this rarely fires)
MAX_STRM_RSS_KB=90000          # strm_svc RSS ceiling (idles ~41MB)
STRM_COOLDOWN=600              # min seconds between amba restarts

CHECK_EVERY=15                 # seconds between checks
OFF_FLAG=/opt/kuna/ha/watchdog.off
LOG=/opt/kuna/ha/kuna-watchdog.log
LOG_MAX=2000
### ---------------------------------------------------------------------------

log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
  [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ] && \
    { tail -n $((LOG_MAX/2)) "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; }
}
now() { cut -d. -f1 /proc/uptime; }
prio_of() { chrt -p "$1" 2>/dev/null | sed -n 's/.*priority: *//p' | tail -1; }
is_rr()   { chrt -p "$1" 2>/dev/null | grep -q SCHED_RR; }

ensure_prio() {
  # $1 = process name, $2 = wanted SCHED_RR priority
  p=$(pidof "$1" 2>/dev/null | tr ' ' '\n' | head -1)
  [ -n "$p" ] || return
  if ! is_rr "$p" || [ "$(prio_of "$p")" != "$2" ]; then
    chrt -r -p "$2" "$p" 2>/dev/null && log "set $1 (pid $p) -> SCHED_RR $2"
  fi
}

mem_free_kb() { awk '/^MemFree:/{print $2}' /proc/meminfo; }
strm_rss_kb() { p=$(pidof strm_svc 2>/dev/null); [ -n "$p" ] && grep VmRSS /proc/"$p"/status 2>/dev/null | awk '{print $2}'; }

restart_amba() {
  km=$(pidof kunamonitor 2>/dev/null)
  [ -n "$km" ] && { log "mem-guard: SIGUSR1 -> kunamonitor to restart amba [$1]"; kill -USR1 "$km" 2>/dev/null; }
}

log "watchdog v3 start (prio_keeper=$ENABLE_PRIO wifi=$WIFI_PRIO nm=$NM_PRIO mem_guard=$ENABLE_MEM_GUARD)"
last_strm=0
while true; do
  [ -f "$OFF_FLAG" ] && { sleep "$CHECK_EVERY"; continue; }

  # 1. PRIORITY KEEPER (the fix for the offline flaps)
  if [ "$ENABLE_PRIO" = "1" ]; then
    ensure_prio wpa_supplicant "$WIFI_PRIO"
    ensure_prio NetworkManager "$NM_PRIO"
  fi

  # 2. MEM GUARD (genuine pressure only)
  if [ "$ENABLE_MEM_GUARD" = "1" ]; then
    t=$(now); mf=$(mem_free_kb); rss=$(strm_rss_kb)
    if [ $((t - last_strm)) -ge "$STRM_COOLDOWN" ]; then
      if [ -n "$mf" ] && [ "$mf" -lt "$MIN_FREE_KB" ]; then restart_amba "MemFree=${mf}kB"; last_strm=$t
      elif [ -n "$rss" ] && [ "$rss" -gt "$MAX_STRM_RSS_KB" ]; then restart_amba "strm_svc RSS=${rss}kB"; last_strm=$t
      fi
    fi
  fi

  sleep "$CHECK_EVERY"
done

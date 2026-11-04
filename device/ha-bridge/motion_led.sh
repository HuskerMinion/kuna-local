#!/bin/ash
# Flash the status LED red/blue (11) on camera motion, return to solid green (3).
# Install at /opt/kuna/ha/motion_led.sh (chmod +x); started by bridge.sh.
# Disable at runtime: touch /opt/kuna/ha/motion_led.off   (and kill this process)
B=/opt/kuna/bin/kunadb
NORMAL=3      # solid green (idle)   -- see docs/led-palette.md for the full map
ALERT=11      # red/blue alternating (motion)
HOLD=15       # seconds to stay in ALERT after last motion
state=normal
last_end=0
$B -p DB_LED_OVERRIDE -v $NORMAL >/dev/null 2>&1
while true; do
  [ -f /opt/kuna/ha/motion_led.off ] && { sleep 5; continue; }
  m=$($B -g DB_MOTION_OCCURRED 2>/dev/null | sed 's/.*: //')
  now=$(cut -d. -f1 /proc/uptime)
  if [ "$m" = "true" ]; then
    [ "$state" != "alert" ] && { $B -p DB_LED_OVERRIDE -v $ALERT >/dev/null 2>&1; state=alert; }
    last_end=$((now + HOLD))
  elif [ "$state" = "alert" ] && [ "$now" -ge "$last_end" ]; then
    $B -p DB_LED_OVERRIDE -v $NORMAL >/dev/null 2>&1; state=normal
  fi
  sleep 1
done

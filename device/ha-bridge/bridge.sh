#!/bin/ash
# Kuna HA bridge manager: start|stop|restart|status
# Install at /opt/kuna/ha/bridge.sh (chmod +x). Autostart it from the boot path
# (e.g. append "/opt/kuna/ha/bridge.sh start" to kunanetrules.ash, which runs at boot).
PORT=8089
ROOT=/opt/kuna/ha
case "$1" in
  stop|restart)
    pkill -f "httpd -p $PORT" 2>/dev/null
    pkill -f "motion_led.sh" 2>/dev/null
    sleep 1 ;;
esac
case "$1" in
  start|restart|"")
    /usr/sbin/httpd -p $PORT -h $ROOT </dev/null >/dev/null 2>&1
    iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null \
      || iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
    # motion->LED flasher (skip if disabled via motion_led.off)
    if ! pgrep -f "motion_led.sh" >/dev/null 2>&1; then
      $ROOT/motion_led.sh </dev/null >/dev/null 2>&1 &
    fi ;;
esac
case "$1" in
  status)
    pgrep -f "httpd -p $PORT" >/dev/null && echo "httpd: running" || echo "httpd: stopped"
    pgrep -f "motion_led.sh" >/dev/null && echo "motion_led: running" || echo "motion_led: stopped"
    netstat -ltn 2>/dev/null | grep ":$PORT " || echo "not-listening" ;;
esac
exit 0

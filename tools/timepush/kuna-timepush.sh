#!/bin/bash
# Push this host's UTC time to a Kuna camera over SSH.
# The KNP01 has no RTC, so its clock resets on every boot; with the camera's WAN
# blocked it can't reach public NTP. Run this from any always-on LAN host that has
# correct time (e.g. your HA box / a Pi), on a schedule.
#
# Setup:
#   1. Put the camera's root SSH key on this host (chmod 600), set KEY below.
#   2. Set CAM to the camera's LAN IP.
#   3. cron (every 15 min):  */15 * * * * /path/to/kuna-timepush.sh
#
CAM="CAMERA_IP"
KEY="$HOME/.ssh/kuna_root_ecdsa"

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes -o ConnectTimeout=10 "root@$CAM" \
  "date -u -s \"$(date -u '+%Y-%m-%d %H:%M:%S')\"" >/dev/null 2>&1

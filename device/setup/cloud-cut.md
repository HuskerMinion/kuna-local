# Device setup: local RTSP, SSH, and cutting the cloud

All paths are on the camera (BusyBox / ash). The rootfs is UBIFS mounted **read-write**, so
edits persist. Back up every file you touch to `*.orig` first. Replace `<CAMERA_IP>` and
`<YOUR_ECDSA_PUBKEY>` with your own values.

## 1. Open local RTSP (port 554)
```sh
cp /opt/kuna/scripts/kunanetrules.ash /opt/kuna/scripts/kunanetrules.ash.orig
echo 'iptables -A INPUT -p tcp --dport 554 -j ACCEPT' >> /opt/kuna/scripts/kunanetrules.ash
# live, without reboot:
iptables -A INPUT -p tcp --dport 554 -j ACCEPT
```
Stream URLs once the camera is running normally: `rtsp://<CAMERA_IP>:554/stream1` (main),
`/stream2` (sub).

## 2. Persistent SSH root over Wi-Fi
OpenSSH on this firmware is **6.4** — two traps:
- Too old for ed25519 keys (need 6.5+). Use an **ECDSA (nistp256)** key: `ssh-keygen -t ecdsa`.
- It **rejects** `PermitRootLogin prohibit-password` (7.0+ syntax) and `sshd` then refuses to
  start. Use `PermitRootLogin yes` (still key-only, because `PasswordAuthentication no`).

```sh
# AuthorizedKeysFile in sshd_config points at /opt/kuna/etc/ssh/authorized_keys
mkdir -p /opt/kuna/etc/ssh
echo '<YOUR_ECDSA_PUBKEY>' >> /opt/kuna/etc/ssh/authorized_keys
chmod 700 /opt/kuna/etc/ssh; chmod 600 /opt/kuna/etc/ssh/authorized_keys
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config      # NOT prohibit-password
sshd -t && echo config-ok                               # must pass
echo 'iptables -A INPUT -p tcp --dport 22 -j ACCEPT' >> /opt/kuna/scripts/kunanetrules.ash
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
```

## 3. Cut the cloud (device side)
Replace the cloud scripts + updater with a no-op so neither startup nor the monitor restart them:
```sh
for f in /opt/kuna/scripts/kunavpn.ash /opt/kuna/scripts/kunasync.ash \
         /opt/kuna/scripts/kunabeat.ash /opt/kuna/bin/kunaupdate; do
  cp "$f" "$f.orig"; printf '#!/bin/ash\nexit 0\n' > "$f"; chmod 755 "$f"
done
pkill -f kunabeat    # stop the running connectivity watchdog now (see note)
```
**Why `kunabeat` matters:** it's a cloud connectivity watchdog. With the cloud blocked its
heartbeat always fails, so it takes "drastic action" — restart Wi-Fi, restart VPN, and finally
**reboot the whole unit** — on a loop. Neutering it stops the reboot loop; NetworkManager then
handles normal Wi-Fi. It does **not** control the light (that's `kunalight`).

## 4. Cut the cloud (network side) — required
AWS IoT MQTT is compiled into the essential `kunaimage` binary, so it can't be removed on-device
without breaking the camera. Block it at the router instead:

> Add a Gateway ACL: **Deny, LAN→WAN, Source = camera IP, Destination = Any, All protocols.**

This severs AWS IoT + heartbeat + any update download in one rule, while LAN↔LAN stays intact so
your NVR and SSH still reach the camera.

## 5. Clock / time (no RTC on this board)
The board has no RTC, so the clock powers on at ~2004 and resets on every boot; with WAN blocked it
can't reach public NTP. Point it at a LAN time source `<NTP_HOST>` (e.g. a Pi running chrony with
`allow <lan>/24`):

- **Continuous sync (recommended).** Run the busybox `ntpd` client so the clock stays disciplined all
  day, instead of drifting between a once-daily `ntpdate` (an RTC-less board drifts seconds per hour).
  Footprint is negligible — ~364 kB RSS, ~0% CPU, normal (non-RT) priority:
  ```sh
  ntpdate -s -u <NTP_HOST>                         # step to correct now
  pidof ntpd >/dev/null 2>&1 || ntpd -p <NTP_HOST>  # then keep it disciplined
  ```
- **Re-base stream timestamps after a cold boot.** At boot the clock sits at ~2004 for the first
  ~30–60 s until NTP lands, and `strm_svc` often starts in that window and **latches 2004 into its
  RTSP/RTP timestamps**. An NVR (e.g. AmberSight) then reports the camera's clock as ~22 years slow
  even though the *system* clock is already correct. Fix by restarting `strm_svc` **after** the clock
  is sane — `kunamonitor` respawns it immediately: `pkill -x strm_svc`.
- **Persist both** in the boot path (`kunanetrules.ash`), guarded against duplicates:
  ```sh
  echo 'pidof ntpd >/dev/null 2>&1 || ntpd -p <NTP_HOST> >/dev/null 2>&1 &' >> /opt/kuna/scripts/kunanetrules.ash
  # bounce strm_svc once, after the clock syncs, so it never latches 2004:
  printf '%s\n' '( for i in $(seq 1 90); do y=$(date +%Y); if [ "$y" -ge 2020 ] && pidof strm_svc >/dev/null 2>&1; then sleep 5; pkill -x strm_svc; break; fi; sleep 2; done ) &' >> /opt/kuna/scripts/kunanetrules.ash
  ```

Alternatives: a narrow WAN-allow for UDP 123 only, or push time from a LAN host over SSH
(`tools/timepush/`).

## 6. Verify
```sh
ssh -i <your_key> root@<CAMERA_IP> \
  'id; ping -c1 -W2 8.8.8.8 >/dev/null && echo WAN_UP || echo WAN_BLOCKED; \
   ifconfig tun0 >/dev/null 2>&1 && echo tun0 || echo no_tun0'
# expect: uid=0(root) ... / WAN_BLOCKED / no_tun0
```

## 7. Camera drops offline / overload (diagnosis + watchdog)
The A5s is a **single core** with **128 MB RAM and no swap**. A 24/7 NVR that pulls *both*
RTSP streams at once (`stream1` main **and** `stream2` sub) pins it:

- `strm_svc` (the RTSP server) runs at **real-time priority**. Under a dual-stream pull the
  core sits at **load ~5**, and the RT `strm_svc` **starves `sshd` and `wpa_supplicant` of
  CPU**. Symptom: **ping still answers but SSH times out**, and the Wi-Fi link can drop
  because the supplicant can't run. It is not "the box is down" — it's CPU starvation.
- `strm_svc` RSS creeps up over time. With no swap, after enough hours this exhausts RAM and
  the unit wedges until a power cycle (first reboot alone won't help — the NVR reconnects both
  streams and it re-overloads within minutes).
- `pulseaudio` also runs at RT priority and burns a core when not suspended.

**Confirm which it is:** from a LAN host, `ping <CAMERA_IP>` while `ssh` fails = starvation
(not an outage). On the box: `cat /proc/loadavg`, `netstat -tn | grep -c ':554 '` (number of
RTSP sessions), and per-process CPU/RSS. The kernel log is useless here — OSD debug spam
overwrites `dmesg` within seconds and there is no `syslogd` — so run the health logger
(`tools/healthlog/`) from a Pi to capture the next incident.

### Fixes (no quality loss)
1. **Record `stream1` only** on the NVR (full-res main). Stop pulling `stream2` 24/7. This
   roughly halves the camera's load with zero loss to recorded quality. Biggest single win.
2. **Front the camera with go2rtc/MediaMTX** on an always-on host: one RTSP session to the
   camera, fanned out (passthrough copy, no re-encode) to the NVR and any live viewers. Caps
   the camera at a single session no matter how many things watch.
3. **Quiet the OSD log flood** (frees CPU, restores `dmesg`): `echo 3 > /proc/sys/kernel/printk`.
   Persist it by adding that line to the boot path (`kunanetrules.ash`).
4. **Suspend idle audio** (keeps audio, frees a core when nothing is playing): uncomment
   `load-module module-suspend-on-idle` in `/etc/pulse/system.pa` and restart `pulseaudio`
   (`kunapulse` respawns it). Recorded audio rides the encoder's AAC track, so it is unaffected.
5. **Install the watchdog** (`device/watchdog/kuna-watchdog.sh`) as a safety net. It **never
   reboots** the unit (unlike stock `kunabeat`): it bounces Wi-Fi via `nmcli` if the gateway
   goes unreachable, and restarts just `strm_svc` (which `kunamonitor` respawns, resetting RSS)
   under memory pressure. Install at `/opt/kuna/ha/kuna-watchdog.sh` and start it from the boot
   path next to the HA bridge:
   ```sh
   echo '/opt/kuna/ha/kuna-watchdog.sh >/dev/null 2>&1 &' >> /opt/kuna/scripts/kunanetrules.ash
   ```
   Disable at runtime with `touch /opt/kuna/ha/watchdog.off`; it logs to `/tmp/kuna-watchdog.log`.

## Reverting a unit
Restore every `*.orig`, remove the added `authorized_keys` line and the `PermitRootLogin yes`
line, delete the HA bridge autostart line, the watchdog autostart line, and the router ACL.

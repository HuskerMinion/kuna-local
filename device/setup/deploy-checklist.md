# Per-unit deployment checklist

A unit is only "done" when **every** box below is checked. The steps are independent, and a
**partially-applied** conversion has bitten us: neutering `kunavpn` but leaving `kunabeat` running
gives a unit that looks fine for ~16 minutes, then **reboot-loops forever** (kunabeat panics when
the cloud is unreachable — see `cloud-cut.md` §3). Run the **Verify gate** at the end on every unit;
it catches a missed step before you walk away.

All commands run on the camera (BusyBox / ash). Replace `<CAMERA_IP>`, `<NVR_IP>`,
`<WIFI_PROFILE>`, `<YOUR_ECDSA_PUBKEY>` with your own values. Back up every file you touch to
`*.orig` first.

---

## Steps

- [ ] **1. Root shell** — USB console (`115200`, log in as `root`) or SSH key. First unit only may
      need the UART/AMBoot teardown; every other unit roots with zero soldering (README §6).

- [ ] **2. Open local RTSP + SSH** (port 554 + 22), live **and** persisted in `kunanetrules.ash`:
      ```sh
      cp /opt/kuna/scripts/kunanetrules.ash /opt/kuna/scripts/kunanetrules.ash.orig
      for p in 554 22; do
        iptables -A INPUT -p tcp --dport $p -j ACCEPT
        echo "iptables -A INPUT -p tcp --dport $p -j ACCEPT" >> /opt/kuna/scripts/kunanetrules.ash
      done
      ```

- [ ] **3. Persistent SSH root key** (OpenSSH 6.4 → **ECDSA** key, `PermitRootLogin yes` NOT
      `prohibit-password`):
      ```sh
      mkdir -p /opt/kuna/etc/ssh
      echo '<YOUR_ECDSA_PUBKEY>' >> /opt/kuna/etc/ssh/authorized_keys
      chmod 700 /opt/kuna/etc/ssh; chmod 600 /opt/kuna/etc/ssh/authorized_keys
      grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
      sshd -t && echo config-ok     # must print config-ok
      ```

- [ ] **4. Neuter ALL cloud scripts** — `kunavpn`, `kunasync`, **`kunabeat`**, and the updater.
      **`kunabeat` is the one that reboot-loops the unit; do not skip it.** Replacing the `.ash`
      stops boot/monitor relaunching it; the `pkill` stops the instance already running:
      ```sh
      for f in /opt/kuna/scripts/kunavpn.ash /opt/kuna/scripts/kunasync.ash \
               /opt/kuna/scripts/kunabeat.ash /opt/kuna/bin/kunaupdate; do
        [ -f "$f.orig" ] || cp "$f" "$f.orig"
        printf '#!/bin/ash\nexit 0\n' > "$f"; chmod 755 "$f"
      done
      # kill the running kunabeat wrapper + binary by PID (NOT `pkill -f kunabeat`,
      # which also matches your own SSH shell and kills your session):
      for pp in $(ps | grep kunabeat | grep -v grep | awk '{print $1}'); do
        [ "$pp" = "$$" ] || kill "$pp" 2>/dev/null
      done
      ```

- [ ] **5. Router ACL — deny the camera all WAN** (AWS IoT is baked into `kunaimage`, cut it at the
      network): *Deny, LAN→WAN, Source = `<CAMERA_IP>`, Destination = Any, all protocols.* Keep
      LAN↔LAN intact so the NVR and SSH still reach it.

- [ ] **6. Clock / time** (no RTC): point the camera at a LAN NTP source and keep it disciplined —
      continuous `ntpd -p <NTP_HOST>` plus a boot hook that bounces `strm_svc` once after the clock
      syncs, so it doesn't latch the ~2004 power-on time into the stream and make the NVR report the
      clock as decades slow. See `cloud-cut.md` §5. Verify the year is **not** 2004 and `pidof ntpd` is set.

- [ ] **7. Resilience watchdog** — install `device/watchdog/kuna-watchdog.sh` at
      `/opt/kuna/ha/kuna-watchdog.sh`, **set `CONN=<WIFI_PROFILE>` for this unit**, and autostart it
      from `kunanetrules.ash`. (It heals Wi-Fi/`strm_svc`; it only reboots for a wedged radio or a
      dead stream, capped — it is not kunabeat.)

- [ ] **8. HA bridge** — install `device/ha-bridge/` (`kuna`, `bridge.sh`, `motion_led.sh`),
      autostart `bridge.sh` from `kunanetrules.ash`, confirm port **8089** answers.

- [ ] **9. (Optional) Restrict RTSP to the NVR** — limit `:554` to `<NVR_IP>` instead of the whole
      LAN, for a single-viewer camera.

- [ ] **10. Motion → LED** — `motion_led.sh` running (solid green idle, red/blue on motion).

---

## Verify gate — run on EVERY unit before considering it done

```sh
echo "== cloud scripts (want: all 'exit 0') =="
for f in kunavpn kunasync kunabeat; do
  printf '  %-9s ' "$f"; sed -n '2p' /opt/kuna/scripts/$f.ash
done
echo "== kunabeat running? (want: NONE) ==";   echo "  pidof kunabeat=$(pidof kunabeat || echo NONE)"
echo "== updater (want: exit 0) ==";            sed -n '2p' /opt/kuna/bin/kunaupdate
echo "== WAN blocked (want: WAN_BLOCKED) ==";   ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && echo "  WAN_UP !!" || echo "  WAN_BLOCKED"
echo "== no VPN tunnel (want: no_tun0) ==";     ifconfig tun0 >/dev/null 2>&1 && echo "  tun0 !!" || echo "  no_tun0"
echo "== ports open (want: 554 and 22) ==";     netstat -tln 2>/dev/null | grep -E ':(554|22) ' | awk '{print "  "$4}'
echo "== watchdog up + CONN set =="
echo "  watchdog_pid=$(pgrep -f kuna-watchdog.sh || echo NONE)  CONN=$(grep -m1 '^CONN=' /opt/kuna/ha/kuna-watchdog.sh | cut -d= -f2 | cut -d' ' -f1)"
echo "== HA bridge :8089 (want: a pid) ==";      echo "  httpd_8089=$(netstat -tln 2>/dev/null | grep -c ':8089 ')"
echo "== clock sane + ntpd (want: current year, not 2004, and an ntpd pid) =="; date; echo "  ntpd=$(pidof ntpd || echo NONE)"
```

**All-clear looks like:** every cloud script `exit 0`, `pidof kunabeat=NONE`, `WAN_BLOCKED`,
`no_tun0`, 554 + 22 listening, watchdog pid present with the right `CONN`, `:8089` = 1, year
current. Any line with `!!` or `NONE`/`2004` where it shouldn't be = an incomplete step; fix it
before leaving the unit.

---

## Revert a unit
Restore every `*.orig`, remove the added `authorized_keys` and `PermitRootLogin yes` lines, the
bridge/watchdog autostart lines, and the router ACL.

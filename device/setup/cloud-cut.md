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
The board has no RTC, so the clock resets on every boot, and with WAN blocked it can't reach a
public NTP server. Options: (a) add a narrow WAN-allow for UDP 123 only, or (b) push time from a
LAN host over SSH — see `tools/timepush/`.

## 6. Verify
```sh
ssh -i <your_key> root@<CAMERA_IP> \
  'id; ping -c1 -W2 8.8.8.8 >/dev/null && echo WAN_UP || echo WAN_BLOCKED; \
   ifconfig tun0 >/dev/null 2>&1 && echo tun0 || echo no_tun0'
# expect: uid=0(root) ... / WAN_BLOCKED / no_tun0
```

## Reverting a unit
Restore every `*.orig`, remove the added `authorized_keys` line and the `PermitRootLogin yes`
line, delete the HA bridge autostart line, and remove the router ACL.

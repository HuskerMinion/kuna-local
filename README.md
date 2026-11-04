# kuna-local

**Reclaim a Kuna "Maximus" porch-light camera (KNP01 / Ambarella A5s) from the cloud — root it,
run local RTSP into your own NVR, control every function from Home Assistant, and cut it off from
Kuna's servers entirely. No subscription, no cloud, no destroyed hardware.**

These are cloud-dependent cameras tied to a Kuna account (and, for some features, a subscription).
This frees the hardware to run **fully local** — so it keeps working regardless of the account,
subscription, or cloud service, and so your video never leaves your LAN.

What you get:
- 🔓 **Root** over Wi-Fi (SSH) and a rock-solid USB-serial console
- 📹 **Local RTSP** (`/stream1` main, `/stream2` sub) for any NVR
- ☁️ **Cloud fully cut** — no VPN tunnel, no AWS IoT, updates blocked
- 💡🔊🎤 **Light, speaker, and mic** controllable locally (see the HA bridge)
- 🟢 **RGB status LED** reprogrammed — solid green idle, red/blue on motion (fully mapped palette)
- 📶 **Local Wi-Fi provisioning** — join/change networks over USB or SSH, even straight from a
  Wi-Fi **QR code** (no Kuna app needed)
- 🏠 A ready-to-drop-in **Home Assistant** package

> ⚠️ This is for hardware **you own**. Reverse-engineering your own device for
> interoperability/repair is well-established, but you are responsible for how you use it.

---

## Hardware

- **Product:** Kuna "Maximus" / Camera Porch Light, 2015 **KNP01** board (`EP-KNP01MB-03`).
- **SoC:** Ambarella **A5S-C0** (a5s55) — ARMv6, H.264.
- **Wi-Fi:** Atheros (SDIO). **Bluetooth:** on-board BLE companion MCU (drives the status LED).
- **Storage:** parallel **NAND** (not clip-and-dump friendly — the UART route below is preferred).
- **Software:** Linux 3.8.8 (BusyBox), Ambarella AMBoot bootloader, OpenSSH **6.4**.

The camera already runs an RTSP server (`strm_svc`) on `0.0.0.0:554`, but a default-DROP firewall
blocks the LAN from reaching it; the cloud gets in through an OpenVPN tunnel (`tun0`) and talks to
Kuna over AWS IoT (MQTT). The whole game is: open 554 to the LAN, add our own root, cut the cloud.

---

## The journey

### 1. Finding the serial console (the hard part)
No populated header — the console is on bare gold test pads next to the SoC.

- **Traps that cost the most time:** several test pads near the NAND look like a UART but are
  the **NAND data/clock bus** — they never decode at any baud. And the obvious 8-pin SOIC by the
  audio section is **not** flash; it's an **SGM4890 audio amplifier**.
- **How to find TX:** scope each candidate pad across a power-cycle. The console TX **idles high
  (~3.3 V), bursts for the first couple seconds of boot, then returns to high and stays there.**
  NAND/bus lines are continuously active or drop to 0 V when idle.
- **Baud:** don't sweep blindly (a UART returns ~12% garbage at *every* wrong baud). Zoom the
  scope to ~10–25 µs/div and measure the **narrowest single pulse** = one bit. Here it's
  **115200 8N1**. The mask-ROM prints `aaaa NAND BIOS: 0x00000000` on a clean, well-grounded capture.
- **Grounding gotcha:** if adding your ground wire makes TX "go silent," the wire is shorting TX
  to an adjacent pad — move to a clean ground and confirm no continuity to TX.

### 2. Interrupt AMBoot → root shell
The bootROM prints one line, then AMBoot boots **silently** and Linux doesn't put a console on
the UART by default. But AMBoot checks the console RX for a keypress early in boot:

1. Wire FTDI **RXD→board TX, TXD→board RX, GND→GND, 3.3 V**.
2. **Spam Enter** while power-cycling → you land at `amboot>`.
3. `show ptb` — **record the original `cmdline`, you must restore it later.**
4. Change `init=/linuxrc` → `init=/bin/sh` and add `console=ttyS0,115200`, then `reboot` → root shell.
   - **Gotcha:** AMBoot's parser drops characters on fast input — send the `setenv` line **one
     character at a time**, read it back with `show ptb`, and **don't** wrap the value in quotes
     (it stores them literally).

The rootfs is **UBIFS mounted read-write**, so your changes persist. Full device steps:
[`device/setup/cloud-cut.md`](device/setup/cloud-cut.md).

### 3. Cut the cloud (and the reboot-loop surprise)
Open 554 + 22 to the LAN, add an **ECDSA** SSH key (OpenSSH 6.4 is too old for ed25519, and
`PermitRootLogin prohibit-password` actually crashes `sshd` — use `PermitRootLogin yes`), neuter
the cloud scripts, and add a **router ACL denying the camera all WAN** (AWS IoT is baked into the
essential `kunaimage`, so it's cut at the network).

> **Watch out:** once the cloud is blocked, the `kunabeat` connectivity watchdog panics — it
> restarts Wi-Fi, the VPN, and eventually **reboots the whole unit, on a loop.** Neuter it too and
> the unit becomes *more* stable than it was on the cloud.

### 4. Local control + Home Assistant
Everything runs off an on-device key/value store (`kunadb`, a Berkeley DB). This repo adds a tiny
**BusyBox-httpd CGI bridge** ([`device/ha-bridge/`](device/ha-bridge/)) on port **8089** that maps
clean URLs to `kunadb`, so Home Assistant can drive it with plain `rest`/`rest_command`:

| Function | How |
|----------|-----|
| Light on/off/brightness | `DB_USER_OVERRIDE` + `DB_LIGHT_BRIGHTNESS` |
| Speaker (built-in clips, volume, siren) | `paplay` + `DB_ALARM_ON` |
| Mic | `arecord` (confirmed capture) |
| Status LED | `DB_LED_OVERRIDE` / `DB_LED_MASK` (see [`docs/led-palette.md`](docs/led-palette.md)) |
| Motion | `DB_MOTION_OCCURRED` |

Drop [`homeassistant/kuna_porch_package.yaml`](homeassistant/kuna_porch_package.yaml) into your HA
`packages/` dir (set your camera IP) for a dimmable light, siren switch, LED-off switch, volume &
motion-timeout sliders, sound buttons, and daytime/RTSP sensors.

The **motion→LED** flasher ([`device/ha-bridge/motion_led.sh`](device/ha-bridge/motion_led.sh))
runs entirely on-device: solid green idle, red/blue on motion, back to green ~15 s after it clears
— works even if HA is down.

### 5. Clock / time
No RTC on the board, so the clock resets on boot and (with WAN blocked) can't reach public NTP.
Push time from any LAN host over SSH on a schedule:
[`tools/timepush/kuna-timepush.sh`](tools/timepush/kuna-timepush.sh).

### 6. One password for the whole Kuna lineup
The root password lives in the **shared firmware rootfs**, so the same `/etc/shadow` hash appears
**byte-for-byte across Kuna models** — confirmed on both the **KNP01** porch light and the Kuna
**"Toucan"** camera (board codename *Coconut*), despite completely different hardware. Recover it
once and it works on the whole (older, discontinued) lineup.

- Hash in `/etc/shadow` — old **DES crypt**, so only the **first 8 characters** matter:
  ```
  root:T/KFBJ/AD6qjc
  ```
- **How to recover it:** it's *not* a plain dictionary word, but it **is** a rule-mutated one.
  Pure brute force would take hours-to-weeks; it falls to **`rockyou.txt` × the `dive` ruleset in
  ~2 minutes** on a modern GPU:
  ```
  hashcat -m 1500 -a 0 hash.txt rockyou.txt -r /usr/share/hashcat/rules/dive.rule
  ```
  (`-m 1500` = `descrypt`. Lesson: always try wordlist + rules before brute force.) Pull the hash
  above — or your own unit's from `/etc/shadow` — and crack it yourself; it's a couple of minutes.

> Kuna is still an active company, so out of respect for them and any current customers this repo
> ships the **hash and the exact method** (fully reproducible) but **not** the plaintext. Crack it
> yourself — it's trivial, but it shouldn't be a copy-paste handout.

**The easy path — no soldering.** Once you've recovered the password, you only ever needed the
UART/AMBoot teardown on the *first* unit (to discover all of this). Every other unit — any Kuna
model — roots with **zero soldering**:

1. Plug the internal **micro-USB** into a PC. It enumerates as a USB-serial console
   (`VID 0525 / PID A4A7`, the Linux gadget-serial device).
2. Open that COM port at **115200** and press Enter.
3. Log in as **`root`** with the password you recovered → root shell.
4. Add your SSH key and run the setup in [`device/setup/cloud-cut.md`](device/setup/cloud-cut.md).

The scope/AMBoot sections above are kept for the record — and in case a future model's password
ever differs (then you re-crack that one with the method above).

---

## Repo layout

```
device/ha-bridge/   on-camera HTTP->kunadb bridge (kuna CGI, bridge.sh, motion_led.sh)
device/setup/       local RTSP, SSH, cloud-cut steps
homeassistant/      HA package (set CAMERA_IP)
tools/timepush/     push time to the camera from a LAN host
tools/wifi/         provision/join/change Wi-Fi over USB or SSH, incl. from a QR code
docs/               LED palette, Wi-Fi guide, images
```

See [`docs/wifi.md`](docs/wifi.md) for Wi-Fi provisioning (USB console for a unit not yet on your
network, or the HTTP bridge once it's online) — including joining straight from a Wi-Fi QR code.

## Safety / revert
To fully revert a unit: restore every `*.orig`, remove the added `authorized_keys` and
`PermitRootLogin yes` lines and the bridge autostart line, and delete the router ACL. The
bootloader `cmdline` is already back to stock after step 2.

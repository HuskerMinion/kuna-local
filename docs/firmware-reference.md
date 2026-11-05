# Kuna KNP01 firmware reference & local-capability map

What's inside the firmware, how to drive it locally, and which built-in features are
reachable without the cloud. Everything here is controlled through **`kunadb`** (a Berkeley
DB key/value store, `/opt/kuna/bin/kunadb`) which the on-camera services watch — the same
mechanism the HA bridge (`device/ha-bridge/`) already uses.

```sh
/opt/kuna/bin/kunadb -g <KEY>            # read
/opt/kuna/bin/kunadb -p <KEY> -v <VAL>   # write
/opt/kuna/bin/kunadb -l                  # list all keys with type + description
/opt/kuna/bin/kunadb --delkey <KEY>      # delete
```

## Stream stack (Ambarella A5s SDK)
`strm_svc` (`/usr/bin/strm_svc`) is the Ambarella cloudcam stream server. `ldd` shows the
`libamstream*` / `libam*` SDK stack. Source-path strings reveal the modules:
- RTSP server + muxers in `libamstreamoutput.so.0`: `rtsp/`, plus `rtp_packager_{h264,aac,
  opus,g726,mjpeg}` — i.e. it can emit **H.264/AAC/Opus/G726/MJPEG**.
- Output formats: `/etc/camera/record.conf` (`FileType0 = RTSP`), **`record.conf.hls`** and
  **`record.conf.http`** variants exist → HLS and HTTP(-FLV/TS) output are supported, not
  just RTSP.
- `libampmdptz` (`get/set_dptz_param`) → **digital PTZ** (on-sensor pan/tilt/zoom).
- `libamoverlay` + `libfreetype` → text/OSD overlay (timestamp/motion box).
- `libamencdev`, `libamvdevice`, `libamsimplecam` → encoder/vin/photo.
- `libpulse`/`libopus` + `pulseaudio` (`--system`, RT priority) → audio in/out.
- `libamwatchdog` → SDK watchdog. `libiniparser` → reads the `/etc/camera/*.conf` files.

Streams: `stream1` = main H.264 1280x720, `stream2` = sub ~848x480. `strm_svc` runs at
**real-time priority** and tears a client down on an RTCP-RR inactivity timeout — see
[`strm-rtcp-timeout-patch.md`](strm-rtcp-timeout-patch.md).

## `/etc/camera/*.conf` (iniparser configs)
`record.conf` (+ `.hls`/`.http`), `vdevice.conf`, `video_vin.conf`/`photo_vin.conf`,
`vout.conf`, `audio.conf`, `audiodetect.conf`, `motiondetect_mse.conf`, `lbr.conf`
(low-bitrate control), `photo.conf`, and **`GlassBreak.bsm`** (a glass-break sound model).
So on-device **motion, audio, and glass-break detection** models ship in the firmware.

## kunadb keyspace (58 keys, grouped)
**Light / schedule**
- `DB_BULB_STATUS` BOOL — lightbulb state
- `DB_LIGHT_BRIGHTNESS` INT 0-100
- `DB_USER_OVERRIDE` JSON — manual override (bridge uses this for on/off)
- `DB_DAYTIME` BOOL — dusk/dawn sensor (this is what auto-turns the light on at night)
- `DB_SCHED_WEEKDAY` / `DB_SCHED_WEEKEND` / `DB_SCHED_CUSTOM` JSON — on/off schedules
- `DB_DUSK_OFFSET` / `DB_DAWN_OFFSET` INT — minutes before/after dusk/dawn

**Motion / PIR**
- `DB_MOTION_OCCURRED` BOOL — video-motion trigger (bridge/LED flasher reads this)
- `DB_PIR_EVENT` UCHAR — bumped on each PIR event (separate hardware PIR source)
- `DB_PIR_SETTINGS` / `DB_PIR_SETTINGS_OVERRIDE` JSON — PIR range/sensitivity
- `DB_SENSITIVITY` UCHAR — motion slider; `DB_KUNAMOTION_CONFIG` UINT
- `DB_AMB_ROI` JSON — motion regions-of-interest
- `DB_MOTION_TIMEOUT` UINT — seconds light stays on after motion
- `DB_SIGHT_PRETRIGGER` / `DB_SIGHT_POSTTRIGGER` / `DB_SIGHT_UPLOAD` — "sight" clip/JPEG
  event pipeline (cloud uploader; where audio/glass-break detections likely route)

**Audio**
- `DB_PLAY_AUDIO` STRING — play a named clip from `/opt/kuna/share/audio_recordings/`
- `DB_AUDIO_VOLUME` UINT — non-alarm volume; `DB_ALARM_VOLUME` UINT (0-65535)
- `DB_ALARM_ON` BOOL — siren
- `DB_PRERECORDED_MESSAGE` / `DB_MESSAGE_ON_RECORD` UINT — canned message (on detection)
- `DB_CUSTOM_MESSAGES` JSON — custom message ids
- Clips present: alarm, chime, dog0-3, can-i-help-you, not-interested, thanks-for-coming,
  busy, voicemail, ghost, halloween, holidays set, plus a `numbers/` dir.
- Audio daemon: `kunaaudio` (respawned by `kunaaudio.ash`). Mic capture via `arecord`,
  playback via `paplay` (both confirmed working).

**Video / image**
- `DB_OVERLAY_TIMESTAMP` BOOL — toggle the timestamp overlay (no binary patch needed)
- `DB_OVERLAY_MOTION` BOOL — toggle motion-box overlay
- `DB_VIDEO_FLIP` BOOL — flip image; `DB_IMG_GAMMA` UINT (gamma*10, 10-30)
- `DB_IMG_DAYTIME` / `DB_IMG_NIGHTTIME` JSON — day/night image settings
- `DB_RTSP_ACTIVE` BOOL — RTSP being viewed (note: unreliable; read as stale)

**Recording (on-device)**
- `DB_RECORD_START` JSON — start a recording; `DB_RECORD_STOP` BOOL; `DB_RECORD_ACTIVE`
  BOOL; `DB_RECORD_RATE` UINT (kBps upload rate)

**Status LED (BLE companion MCU)**
- `DB_LED_OVERRIDE` UCHAR (palette, see `docs/led-palette.md`); `DB_LED_MASK` BOOL (off)
- `DB_COMPANION_GROUP` UINT / `DB_COMPANION_COMMAND` JSON — signal attached BLE companions

**System / network / deprecated**
- `DB_WIFI_SETTINGS` JSON (ssid/pass/type/hidden), `DB_WIFI_IPADDR`, `DB_WIFI_STATS`,
  `DB_WIFI_NETWORK`, `DB_MISC_STATS`, `DB_NETWORK_ACTIVE` (heartbeat), `DB_LOCATION` JSON
- `DB_REBOOTS` JSON (error-reboot counter — useful to watch), `DB_STATS_FILTER`,
  `DB_KUNALOG_LIMIT`, `DB_IOT_ENDPOINT` JSON (AWS IoT)
- Deprecated: `DB_SIGHT_CONFIG`, `DB_IOBEAM_REGISTERED`, `DB_IOBEAM_TOKEN`,
  `DB_VPN_IPADDR`, `DB_VPN_SRVADDR`

## Local feature opportunities (grounded in the above)
Status: ✅ ready via kunadb/bridge · 🟡 plausible, needs a little work · 🔬 needs investigation

| Feature | Mechanism | Status |
|---|---|---|
| Timestamp overlay on/off | `DB_OVERLAY_TIMESTAMP` (and `DB_OVERLAY_MOTION`) | ✅ |
| Play any sound / canned message | `DB_PLAY_AUDIO`, `DB_PRERECORDED_MESSAGE`, clips | ✅ (bridge already plays clips) |
| Video flip / gamma / day-night image | `DB_VIDEO_FLIP`, `DB_IMG_GAMMA`, `DB_IMG_*` | ✅ |
| Motion ROI + sensitivity in HA | `DB_AMB_ROI`, `DB_SENSITIVITY`, `DB_KUNAMOTION_CONFIG` | ✅ |
| PIR event as a separate HA sensor | `DB_PIR_EVENT` (distinct from `DB_MOTION_OCCURRED`) | ✅ |
| Light schedules / dusk-dawn offsets | `DB_SCHED_*`, `DB_DUSK_OFFSET`, `DB_DAWN_OFFSET` | ✅ |
| Error-reboot counter in HA | `DB_REBOOTS` | ✅ |
| On-device recording to file/NAS | `DB_RECORD_START/STOP/ACTIVE/RATE` | 🟡 (JSON shape TBD; NAND space limited → push to NAS) |
| Two-way audio / intercom | bridge `do=talk` (POST wav→speaker) + `do=listen` (mic→wav) | ✅ (both tested; live duplex still a separate opus path) |
| JPEG snapshot | bridge `do=snapshot` serves live `/tmp/thumb/thumb.jpg` | ✅ (tested; use as Generic Camera still_image_url) |
| HLS / HTTP viewing | `record.conf.hls` (TS→`/sdcard/video/`), `kunarest` :7777 | 🔬 (`/sdcard` NOT mounted; HLS needs storage + replaces RTSP on stream1) |
| Audio-detect + glass-break events | `audiodetect.conf` (`GlassBreak1/2.bsm`) | 🔬 (both detectors `Enable*Detect=0`; enabling is a config flag, but still need to find where a detection surfaces — kunadb key or callback) |
| Digital PTZ / zoom / privacy mask | `libampmdptz` (`AmPrivacyMaskDPTZ`, `iav_digital_zoom2`) | 🔴 (encoder-internal SDK only; no kunadb key or tool — would need a custom binary) |

### Investigation notes (2026-11-05)
- **`kunarest`** is a local HTTP server on **:7777** (`/api/v1/`, serves `image/jpeg`); the
  camera also keeps a live JPEG at **`/tmp/thumb/thumb.jpg`** (refreshed ~1/s) — that's what
  `do=snapshot` serves. The :7777 API is unmapped (could yield more endpoints).
- **HLS**: `record.conf.hls` targets `/sdcard/video/` but `/sdcard` is an empty unmounted dir.
  Needs a storage mount (NAND partition or NFS/CIFS) and swaps the main stream off RTSP.
- **Detection**: `/etc/camera/audiodetect.conf` ships the glass-break models but has
  `EnableAlertDetect=0` and `EnableAnalysisDetect=0`. Flipping those to 1 arms them; the open
  question is where a hit is reported (no obvious kunadb key — likely the "sight"/`kunaimage`
  path). Needs tracing before it's HA-usable.
- **DO NOT execute `kuna_img_control` / `testbench`** (they block on the imaging IPC and
  restart the live pipeline). `kunaimage` writes the thumbnail; don't poke it directly.

## Safety notes (learned the hard way)
- **Never run `kuna_img_control` or `testbench` with no/`-h` args** — they block (connect to the
  imaging IPC and wait) and running them restarts/disturbs the live `strm_svc` pipeline. Inspect
  with `strings`, not by executing.
- `strm_svc` and `pulseaudio` run at **real-time priority**; heavy work starves `sshd`.
- No RTC; `kunamonitor` can reboot on amba-restart failure (internal, can't be stubbed).
- Rootfs is UBIFS RW so changes persist; back up every file/db value you change.

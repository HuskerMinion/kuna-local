# Optional binary patch: disable the RTSP RR inactivity teardown

**Status: APPLIED 2026-11-05 on this unit (backup at `/opt/kuna/ha/libamstreamoutput.so.0.orig`).**
Reverse-engineering showed the camera's teardown timeout is **adaptive** (recomputed from the
RTCP RR cadence in `HandleRtcpPacket`), so feeding the camera RR does not reliably stop the
teardown and can even shorten the timeout. This patch makes the camera's client `select()`
effectively never time out, so it stops tearing clients down on RR inactivity regardless of
client behaviour; genuine disconnects are still detected via the socket closing.

## What causes the ~6-minute teardown
`strm_svc` (the camera's RTSP server) is the Ambarella SDK stream stack. The client
session logic lives in `libamstreamoutput.so.0`, class `CRtspClientSession`.

- `CRtspClientSession::HandleRtcpPacket` recomputes an **adaptive timeout** from RTCP
  receiver-report timing (`__aeabi_uldivmod` on the RR interval, `(val+2)` then x2/x4)
  and stores it in the session object at **offset +0xb0** (seconds).
- `CRtspClientSession::ClientThread` loops doing `select()` on the client socket with
  that timeout:
  ```
  48e00: ldr ip, [r4, #0xb0]   ; ip = timeout seconds (from +0xb0)
  48e14: str ip, [lr, r3]      ; -> select() timeout tv_sec
  48e38: bl  select
  48e40: cmp r0, #0
  48e44: ble 49954             ; select()==0 (timeout, no RR/data) -> shutdown block
  49984: bl  am_warn           ; "...is not responding within %d seconds, shutdown!"
  4998c: bl  CRtspClientSession::TearDown
  ```
So if no RR/data arrives within `[obj+0xb0]` seconds, `select()` times out and the
session is torn down. That is the ~6-min drop. There is **no static timeout constant**
to bump; the value is adaptive, so the patch targets the `select()` timeout load.

## The patch (single instruction, 4 bytes)
Make the `select()` timeout effectively infinite, so it only returns on real socket
activity (RR/data) or a real error/close — never on an inactivity timeout.

- **Target file:** `/usr/lib/libamstreamoutput.so.0`
  - sha1 (this unit): `b275953bbace8b2c5478c3664b08d6569f0d788e`  size 414700
  - GNU build-id: `cec4711e3016cdbe6916414624940602f98f6379`
  - (rootfs is shared across Kuna models, so the same lib/offset should apply elsewhere;
    re-verify the bytes before patching any other unit.)
- **File offset / vaddr:** `0x48e00` (.text has vaddr == file offset in this lib)
- **Original bytes (LE):** `b0 c0 94 e5`  = `ldr ip, [r4, #0xb0]`  (e594c0b0)
- **Patched  bytes (LE):** `01 c4 a0 e3`  = `mov ip, #0x01000000` (e3a0c401)
  - 0x01000000 s ~= 194 days as `tv_sec` (positive, so no `select()` EINVAL).

Effect: the inactivity teardown never fires. A genuine client disconnect is still
detected normally (socket becomes readable -> recv returns EOF, or select returns <0 ->
the `ble` at 0x48e44 is still taken), so only the *silent-but-connected* timeout is removed.

## Apply (on the camera, as root) — back up first
GOTCHAS (both cost real time once):
- `/usr/lib/libamstreamoutput.so.0` is a **symlink** → `libamstreamoutput.so.0.1.0`. Do NOT
  back up with `cp -a` (it copies the dangling symlink, 26 bytes). Use `cat` (follows it) and
  **verify the backup is 414700 bytes before patching**. `od`/`dd` follow the symlink fine.
- `0x48e00` = **298496** decimal. Use `$((0x48e00))`, never a hand-typed decimal (295936 =
  0x48400 is a different, unrelated instruction — patching there corrupts the lib).
```sh
L=/usr/lib/libamstreamoutput.so.0
cat "$L" > /opt/kuna/ha/libamstreamoutput.so.0.orig          # real backup (follows symlink)
[ "$(stat -c%s /opt/kuna/ha/libamstreamoutput.so.0.orig)" = 414700 ] || echo "BACKUP BAD - STOP"
od -An -tx1 -j $((0x48e00)) -N4 "$L"                          # expect: b0 c0 94 e5
printf '\x01\xc4\xa0\xe3' | dd of="$L" bs=1 seek=$((0x48e00)) conv=notrunc
od -An -tx1 -j $((0x48e00)) -N4 "$L"                          # expect: 01 c4 a0 e3
```
The lib is memory-mapped by the running `strm_svc`, so the change takes effect only after
the amba stack reloads it: `kill -USR1 $(pidof kunamonitor)` (restart amba processes) or
reboot. Watch the health logger (`tools/healthlog/`) to confirm `strm_svc` stops cycling.

## Revert
```sh
L=/usr/lib/libamstreamoutput.so.0
cat /opt/kuna/ha/libamstreamoutput.so.0.orig > "$L"   # follows symlink to the real file
kill -USR1 $(pidof kunamonitor)                       # or reboot
```

## Caveats
- Workaround, not a fix: it makes the camera ignore RTCP liveness entirely, so a client
  that dies without closing its TCP socket is only detected when TCP itself notices
  (keepalive/RST), not after 6 min.
- UBIFS is RW so the change persists, but a firmware/OTA restore would revert it (WAN is
  blocked, so OTA shouldn't happen).
- Re-verify the original bytes on any other unit before patching (confirm same sha1/build-id).

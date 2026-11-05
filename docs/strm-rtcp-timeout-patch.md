# Optional binary patch: disable the RTSP RR inactivity teardown

**Status: APPLIED 2026-11-05 (corrected v2 patch at `0x48e44`). Video confirmed still flowing;
`strm_svc` stopped cycling. Backup at `/opt/kuna/ha/libamstreamoutput.so.0.orig` (414700 B).**

Reverse-engineering showed the camera's teardown timeout is **adaptive** (recomputed from the
RTCP RR cadence in `HandleRtcpPacket`), so feeding the camera RR does not reliably stop the
teardown and can even shorten the timeout — the fix has to be on the camera.

### ⚠️ Do NOT use the first approach (inflating the select timeout at 0x48e00)
The obvious-looking patch — change `ldr ip,[r4,#0xb0]` at `0x48e00` so the `select()` timeout
is huge — **freezes the video** (AmberSight connected, black image). `0x48e00`'s value is not
the select timeval; it is copied into a stream struct, and an infinite select also skips
periodic work the RTP path needs. Tried it, got a black image, reverted. Use the branch patch
below instead.

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
So when `select()` returns `<= 0`, `0x48e44 ble 49954` leads (on `== 0`, a timeout) to the
"not responding -> TearDown -> thread exit" block. That is the drop. The loop head is `0x48df8`
(normal iterations branch back there), so the clean fix is: on a timeout, **branch back to the
loop head instead of to teardown** — leaving the timeout value, the timeval, and all the
per-iteration stream work untouched.

## The patch (single instruction, 4 bytes) — redirect the teardown branch to the loop
Change the `select()<=0` branch so a timeout re-enters the select loop (`0x48df8`) instead of
tearing the session down. Teardown becomes unreachable from the timeout path; a genuine
disconnect is still caught on the data path (socket readable -> recv EOF).

- **Target file:** `/usr/lib/libamstreamoutput.so.0`  (**symlink** → `libamstreamoutput.so.0.1.0`)
  - sha1 (this unit): `b275953bbace8b2c5478c3664b08d6569f0d788e`  size 414700
  - GNU build-id: `cec4711e3016cdbe6916414624940602f98f6379`
  - rootfs is shared across Kuna models, so the offset should apply elsewhere — **re-verify the
    original bytes before patching any other unit.**
- **File offset / vaddr:** `0x48e44` = **298564** decimal (.text vaddr == file offset here)
- **Original bytes (LE):** `c2 02 00 da`  = `ble 49954`  (0xDA0002C2 — branch to teardown)
- **Patched  bytes (LE):** `eb ff ff da`  = `ble 48df8`  (0xDAFFFFEB — branch to loop head)

(The branch offset: `0x48df8 - (0x48e44 + 8) = -0x54` → imm24 `0xFFFFEB`. Verify with
`objdump` that the patched word disassembles to `ble 48df8` before trusting it.)

## Apply (on the camera, as root) — back up first
GOTCHAS (both cost real time once; learned the hard way):
- The `.so` is a **symlink** → back up with `cat` (follows it), NOT `cp -a` (copies the 26-byte
  dangling link). **Verify the backup is 414700 bytes before patching.** `od`/`dd` follow it.
- `0x48e44` = **298564** decimal. Use `$((0x48e44))`, never a hand-typed number.
```sh
L=/usr/lib/libamstreamoutput.so.0
cat "$L" > /opt/kuna/ha/libamstreamoutput.so.0.orig          # real backup (follows symlink)
[ "$(stat -c%s /opt/kuna/ha/libamstreamoutput.so.0.orig)" = 414700 ] || echo "BACKUP BAD - STOP"
od -An -tx1 -j $((0x48e44)) -N4 "$L"                          # expect: c2 02 00 da
printf '\xeb\xff\xff\xda' | dd of="$L" bs=1 seek=$((0x48e44)) conv=notrunc
od -An -tx1 -j $((0x48e44)) -N4 "$L"                          # expect: eb ff ff da
```
The lib is memory-mapped by the running `strm_svc`, so the change takes effect only after the
amba stack reloads it: `kill -USR1 $(pidof kunamonitor)` (restart amba processes) or reboot.
Then confirm BOTH: video still flows (`/tmp/thumb/thumb.jpg` keeps updating ~1/s — not black)
AND `strm_svc` stops cycling (pid holds, logger shows no `down`s past the old ~6-min window).

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

#!/usr/bin/env python3
"""
kuna_wifi.py - manage Wi-Fi on a rooted Kuna unit via NetworkManager (nmcli).

Bootstraps a unit that is NOT yet on Wi-Fi over its USB-gadget serial console
(the internal micro-USB enumerates as a COM port), or manages one already on the
network over SSH. Supports provisioning straight from a standard Wi-Fi QR code.

Examples:
  # scan for networks over the USB console
  python kuna_wifi.py --port COM20 scan
  # join a network (prompts for the login password if not given)
  python kuna_wifi.py --port COM20 join --ssid MyWifi --pass 'secret'
  # join from a Wi-Fi QR code string (WIFI:S:..;T:WPA;P:..;;)
  python kuna_wifi.py --port COM20 qr --string 'WIFI:S:MyWifi;T:WPA;P:secret;;'
  # ...or decode the QR from an image (needs: pip install pyzbar pillow)
  python kuna_wifi.py --port COM20 qr --image wifi.png
  # over SSH instead of serial (unit already on the LAN)
  python kuna_wifi.py --ssh root@CAMERA_IP --key ~/.ssh/kuna_root_ecdsa list
"""
import argparse, getpass, re, subprocess, sys, time

def parse_wifi_qr(text):
    """Parse a 'WIFI:S:<ssid>;T:<auth>;P:<pass>;H:<hidden>;;' string."""
    m = re.match(r'WIFI:', text.strip(), re.I)
    if not m:
        raise ValueError("not a WIFI: QR string")
    body = text.strip()[5:]
    fields = {}
    # split on unescaped ';'
    parts = re.split(r'(?<!\\);', body)
    for p in parts:
        if ':' in p:
            k, v = p.split(':', 1)
            fields[k.upper()] = v.replace('\\;', ';').replace('\\:', ':').replace('\\\\', '\\')
    return fields.get('S', ''), fields.get('P', ''), fields.get('T', 'WPA')

def decode_qr_image(path):
    try:
        from pyzbar.pyzbar import decode
        from PIL import Image
    except ImportError:
        sys.exit("QR image decoding needs: pip install pyzbar pillow  (or pass --string)")
    res = decode(Image.open(path))
    if not res:
        sys.exit("no QR code found in image")
    return res[0].data.decode()

def shq(s):  # single-quote for the remote shell
    return "'" + s.replace("'", "'\\''") + "'"

# ---- transports -------------------------------------------------------------
class SerialTransport:
    def __init__(self, port, pw, baud=115200):
        import serial
        self.s = serial.Serial(port, baud, timeout=1)
        self._login(pw)
    def _rd(self, sec):
        end = time.time() + sec; buf = b""
        while time.time() < end:
            d = self.s.read(8192)
            if d: buf += d
            else: time.sleep(0.05)
        return buf.decode("latin-1", "replace")
    def _login(self, pw):
        self.s.write(b"\r\n"); time.sleep(0.6)
        pre = self._rd(1.2)
        if "login:" in pre.lower():
            self.s.write(b"root\r\n"); time.sleep(0.6); self._rd(2)
            self.s.write(pw.encode() + b"\r\n"); time.sleep(1.2); self._rd(2)
    def run(self, cmd):
        marker = "___END___"
        self.s.write((cmd + "; echo " + marker + "\r\n").encode());
        end = time.time() + 20; buf = ""
        while time.time() < end:
            buf += self._rd(0.4)
            if marker in buf.split("echo", 1)[-1]:
                break
        # strip the echoed command and marker
        out = buf
        out = re.sub(r'.*' + re.escape(marker) + r'.*', '', out)
        return ''.join(c for c in out if (32 <= ord(c) < 127 or c in '\r\n\t'))

class SshTransport:
    def __init__(self, target, key):
        self.base = ["ssh"]
        if key: self.base += ["-i", key]
        self.base += ["-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=/dev/null",
                      "-o","IdentitiesOnly=yes","-o","ConnectTimeout=10", target]
    def run(self, cmd):
        r = subprocess.run(self.base + [cmd], capture_output=True, text=True, timeout=40)
        return r.stdout + r.stderr

# ---- actions ----------------------------------------------------------------
def do_scan(t):
    print(t.run("nmcli -f SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null || iwlist wlan0 scan | grep ESSID"))
def do_list(t):
    print(t.run("nmcli -t -f NAME,TYPE,DEVICE con show"))
def do_forget(t, ssid):
    print(t.run("nmcli con delete " + shq(ssid)))
def do_status(t):
    print(t.run("nmcli -t -f STATE,CONNECTIVITY g; ifconfig wlan0 | grep 'inet addr'"))
def do_join(t, ssid, pw):
    print("joining %r ..." % ssid)
    print(t.run("nmcli dev wifi connect " + shq(ssid) + " password " + shq(pw)))
    time.sleep(4)
    print(t.run("ifconfig wlan0 | grep 'inet addr' || echo 'no IP yet'"))

def main():
    ap = argparse.ArgumentParser(description="Manage Wi-Fi on a rooted Kuna unit (nmcli).")
    ap.add_argument("--port"); ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ssh"); ap.add_argument("--key")
    ap.add_argument("--password", help="root login password (serial only; prompts if omitted)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan"); sub.add_parser("list"); sub.add_parser("status")
    j = sub.add_parser("join"); j.add_argument("--ssid", required=True); j.add_argument("--pass", dest="pw", required=True)
    q = sub.add_parser("qr"); q.add_argument("--string"); q.add_argument("--image")
    f = sub.add_parser("forget"); f.add_argument("--ssid", required=True)
    a = ap.parse_args()

    if a.ssh:
        t = SshTransport(a.ssh, a.key)
    elif a.port:
        pw = a.password or getpass.getpass("Kuna root password: ")
        t = SerialTransport(a.port, pw, a.baud)
    else:
        sys.exit("specify --port COMx (serial console) or --ssh user@host")

    if a.cmd == "scan":   do_scan(t)
    elif a.cmd == "list": do_list(t)
    elif a.cmd == "status": do_status(t)
    elif a.cmd == "forget": do_forget(t, a.ssid)
    elif a.cmd == "join": do_join(t, a.ssid, a.pw)
    elif a.cmd == "qr":
        text = a.string or (decode_qr_image(a.image) if a.image else sys.exit("pass --string or --image"))
        ssid, pw, _ = parse_wifi_qr(text)
        if not ssid: sys.exit("QR had no SSID")
        do_join(t, ssid, pw)

if __name__ == "__main__":
    main()

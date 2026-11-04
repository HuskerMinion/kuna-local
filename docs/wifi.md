# Wi-Fi provisioning & management

Kuna units run **NetworkManager + wpa_supplicant**, so Wi-Fi is just `nmcli`. There are two ways
to manage it, depending on whether the unit is already on your network.

## A. Bootstrapping a unit that is NOT on Wi-Fi yet (USB console)
A fresh/foreign unit (e.g. one previously joined to someone else's SSID) has no route to your LAN,
so you provision it over the **USB-gadget serial console** with
[`tools/wifi/kuna_wifi.py`](../tools/wifi/kuna_wifi.py):

```bash
# see what's in range
python tools/wifi/kuna_wifi.py --port COM20 scan

# join by SSID/password (prompts for the root login password)
python tools/wifi/kuna_wifi.py --port COM20 join --ssid "MyWifi" --pass "secret"

# ...or straight from a Wi-Fi QR code
python tools/wifi/kuna_wifi.py --port COM20 qr --string 'WIFI:S:MyWifi;T:WPA;P:secret;;'
python tools/wifi/kuna_wifi.py --port COM20 qr --image wifi-qr.png   # needs: pip install pyzbar pillow
```

`COM20` is whatever the internal micro-USB enumerates as (`VID 0525 / PID A4A7`). The tool logs in
as root, runs `nmcli dev wifi connect ...`, and NetworkManager persists the profile under
`/etc/NetworkManager/system-connections/`, so it reconnects on every boot.

### Wi-Fi QR format
Standard phone-style Wi-Fi QR codes encode:
```
WIFI:S:<ssid>;T:<WPA|WEP|nopass>;P:<password>;H:<true if hidden>;;
```
Generate one for your network (many routers/apps do this) and the `qr` subcommand provisions the
camera straight from it — no typing credentials into a shell.

## B. Changing/roaming a unit that is already online (HTTP bridge)
Once a unit is on the LAN, the on-device bridge exposes Wi-Fi actions too (handy from Home
Assistant or a script):

```
GET /cgi-bin/kuna?do=wifiscan                      # JSON list of visible SSIDs
GET /cgi-bin/kuna?do=wifilist                       # saved connection profiles
GET /cgi-bin/kuna?do=wifijoin&ssid=<ssid>&pass=<p>  # join/switch network
GET /cgi-bin/kuna?do=wififorget&ssid=<name>         # delete a saved profile
```
(URL-encode SSID/password values.)

## Manual equivalents (straight nmcli on the unit)
```sh
nmcli -f SSID,SIGNAL,SECURITY dev wifi list      # scan
nmcli dev wifi connect "MyWifi" password "secret"  # join + persist
nmcli -t -f NAME con show                         # saved profiles
nmcli con delete "OldNetwork"                     # forget one
```

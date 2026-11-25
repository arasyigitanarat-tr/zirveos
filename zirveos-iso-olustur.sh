#!/bin/bash
# ZirveOS ISO oluşturucu — Debian/Ubuntu üzerinde çalıştır (WSL değil, gerçek Linux veya VM)
# Kullanım:  sudo bash zirveos-iso-olustur.sh   (ZirveOS.html aynı klasörde olmalı)
# Sonuç: zirveos/live-image-amd64.hybrid.iso  -> VirtualBox/VMware/QEMU'ya takıp aç
set -e
[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır"; exit 1; }
[ -f ZirveOS.html ] || { echo "ZirveOS.html bulunamadı"; exit 1; }

apt-get update
apt-get install -y live-build debootstrap squashfs-tools xorriso

rm -rf zirveos && mkdir zirveos && cd zirveos

lb config \
  --distribution bookworm \
  --architectures amd64 \
  --binary-images iso-hybrid \
  --bootappend-live "boot=live components quiet splash hostname=zirveos username=zirve" \
  --iso-application "ZirveOS" --iso-volume "ZIRVEOS" \
  --archive-areas "main contrib non-free non-free-firmware"

# Paketler: ekran sunucusu, tarayıcı, ağ (Wi-Fi), ses, python (sistem hizmeti için), Wi-Fi sürücüleri
mkdir -p config/package-lists
cat > config/package-lists/zirve.list.chroot <<EOF
xorg
openbox
chromium
lightdm
network-manager
alsa-utils
pulseaudio
pulseaudio-utils
python3
sudo
open-vm-tools
firmware-iwlwifi
firmware-realtek
firmware-atheros
firmware-brcm80211
EOF

# ZirveOS arayüzü
mkdir -p config/includes.chroot/opt/zirveos
cp ../ZirveOS.html config/includes.chroot/opt/zirveos/index.html

# ZirveOS sistem hizmeti (Wi-Fi, ses, güç denetimi) — sadece 127.0.0.1'de dinler
cat > config/includes.chroot/opt/zirveos/helper.py <<'PYEOF'
#!/usr/bin/env python3
"""ZirveOS sistem hizmeti: ZirveOS arayüzünü sunar, Wi-Fi/ses/güç komutlarını uygular. Sadece 127.0.0.1'e bağlanır."""
import json, re, os, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
INDEX = "/opt/zirveos/index.html"

def run(args, t=25):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=t)
        return r.returncode, (r.stdout + r.stderr).strip()
    except Exception as e:
        return 1, ""

def fields(line):
    return [p.replace("\\:", ":") for p in re.split(r"(?<!\\):", line)]

def status():
    _, dev = run(["nmcli", "-t", "-f", "TYPE", "dev"])
    _, radio = run(["nmcli", "radio", "wifi"])
    _, act = run(["nmcli", "-t", "-f", "NAME,TYPE", "con", "show", "--active"])
    names = [fields(l)[0] for l in act.splitlines() if l and not l.startswith("lo")]
    vol, muted = None, False
    c, o = run(["pactl", "get-sink-volume", "@DEFAULT_SINK@"])
    m = re.search(r"(\d+)%", o) if c == 0 else None
    if m:
        vol = int(m.group(1))
        muted = "yes" in run(["pactl", "get-sink-mute", "@DEFAULT_SINK@"])[1]
    return {"has_wifi": "wifi" in dev.split(), "wifi_on": radio.strip() == "enabled",
            "active": ", ".join(names), "volume": vol, "muted": muted,
            "host": os.uname().nodename, "kernel": os.uname().release}

def wifi_list():
    _, o = run(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "auto"], 30)
    seen, out = set(), []
    for line in o.splitlines():
        f = fields(line)
        if len(f) < 4 or not f[1] or f[1] in seen:
            continue
        seen.add(f[1])
        out.append({"active": f[0] == "*", "ssid": f[1], "signal": int(f[2] or 0), "sec": f[3] not in ("", "--")})
    return sorted(out, key=lambda n: (not n["active"], -n["signal"]))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def ok_host(self): return self.headers.get("Host", "") in (f"127.0.0.1:{PORT}", f"localhost:{PORT}")
    def send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if not self.ok_host(): return self.send(403, {"error": "host"})
        if self.path in ("/", "/index.html"):
            with open(INDEX, "rb") as f: return self.send(200, f.read(), "text/html")
        if self.path == "/api/status": return self.send(200, status())
        if self.path == "/api/wifi": return self.send(200, wifi_list())
        self.send(404, {"error": "yok"})
    def do_POST(self):
        if not self.ok_host() or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.send(403, {"error": "reddedildi"})
        try: d = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except Exception: return self.send(400, {"error": "json"})
        p = self.path
        if p == "/api/volume":
            v = max(0, min(100, int(d.get("v", 50))))
            run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{v}%"])
            run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" if d.get("mute") else "0"])
            return self.send(200, {"ok": True})
        if p == "/api/wifi/radio":
            run(["nmcli", "radio", "wifi", "on" if d.get("on") else "off"]); return self.send(200, {"ok": True})
        if p == "/api/wifi/connect":
            ssid, pw = str(d.get("ssid", ""))[:64], str(d.get("password", ""))[:128]
            if not ssid: return self.send(400, {"ok": False})
            args = ["nmcli", "dev", "wifi", "connect", ssid] + (["password", pw] if pw else [])
            c, o = run(args, 40); return self.send(200, {"ok": c == 0, "msg": o[-200:]})
        if p == "/api/power" and d.get("act") in ("reboot", "poweroff"):
            self.send(200, {"ok": True}); run(["sudo", "-n", "systemctl", d["act"]]); return
        self.send(404, {"error": "yok"})

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

# Tarayıcı uygulaması için: siteler iframe içinde açılabilsin diye küçük bir Chromium eklentisi
mkdir -p config/includes.chroot/opt/zirveos/ext
cat > config/includes.chroot/opt/zirveos/ext/manifest.json <<'EOF'
{
  "manifest_version": 3,
  "name": "ZirveOS Frame",
  "version": "1.0",
  "permissions": ["declarativeNetRequest"],
  "host_permissions": ["<all_urls>"],
  "declarative_net_request": {
    "rule_resources": [{"id": "r1", "enabled": true, "path": "rules.json"}]
  }
}
EOF
cat > config/includes.chroot/opt/zirveos/ext/rules.json <<'EOF'
[{
  "id": 1, "priority": 1,
  "action": {"type": "modifyHeaders", "responseHeaders": [
    {"header": "x-frame-options", "operation": "remove"},
    {"header": "content-security-policy", "operation": "remove"},
    {"header": "content-security-policy-report-only", "operation": "remove"}
  ]},
  "condition": {"resourceTypes": ["sub_frame"]}
}]
EOF

# Otomatik giriş + tam ekran kiosk
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/50-zirve.conf <<EOF
[Seat:*]
autologin-user=zirve
autologin-session=openbox
EOF

mkdir -p config/includes.chroot/etc/skel/.config/openbox
cat > config/includes.chroot/etc/skel/.config/openbox/autostart <<EOF
xset s off -dpms &
python3 /opt/zirveos/helper.py &
sleep 2
chromium --kiosk --load-extension=/opt/zirveos/ext --no-first-run --noerrdialogs --disable-infobars --user-data-dir=/home/zirve/.zirve-chrome http://127.0.0.1:8765/ &
EOF

lb build
echo "Bitti: $(pwd)/live-image-amd64.hybrid.iso"

#!/bin/bash
# ZirveOS ISO oluşturucu — Debian/Ubuntu üzerinde çalıştır (WSL değil, gerçek Linux veya VM)
# Kullanım:  sudo bash zirveos-iso-olustur.sh   (ZirveOS.html aynı klasörde olmalı)
# Sonuç: zirveos/live-image-amd64.hybrid.iso  -> VirtualBox/VMware/QEMU'ya takıp aç
set -e
[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır"; exit 1; }
[ -f ZirveOS.html ] || { echo "ZirveOS.html bulunamadı"; exit 1; }

apt-get update
apt-get install -y live-build debootstrap squashfs-tools xorriso debian-archive-keyring

rm -rf zirveos && mkdir zirveos && cd zirveos

lb config \
  --distribution bookworm \
  --architectures amd64 \
  --binary-images iso-hybrid \
  --bootappend-live "boot=live components quiet splash hostname=zirveos username=zirve" \
  --iso-application "ZirveOS" --iso-volume "ZIRVEOS" \
  --archive-areas "main contrib non-free non-free-firmware"

# Gerekli paketler: ekran sunucusu + tarayıcı (ZirveOS arayüzü tarayıcıda tam ekran açılır)
mkdir -p config/package-lists
cat > config/package-lists/zirve.list.chroot <<EOF
xorg
openbox
chromium
lightdm
network-manager
alsa-utils
pulseaudio
open-vm-tools
EOF

# ZirveOS dosyasını sisteme koy
mkdir -p config/includes.chroot/opt/zirveos
cp ../ZirveOS.html config/includes.chroot/opt/zirveos/index.html

# Tarayıcı uygulaması için: siteler iframe içinde açılabilsin diye küçük bir Chromium eklentisi
# (X-Frame-Options ve CSP başlıklarını alt çerçevelerde kaldırır)
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
chromium --kiosk --load-extension=/opt/zirveos/ext --no-first-run --noerrdialogs --disable-infobars --user-data-dir=/tmp/zirve file:///opt/zirveos/index.html &
EOF

lb build
echo "Bitti: $(pwd)/live-image-amd64.hybrid.iso"

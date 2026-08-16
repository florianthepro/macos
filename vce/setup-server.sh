#!/usr/bin/env bash
# setup-server.sh - richtet die VCE-Serverseite mit EINEM Befehl ein.
# Erzeugt im Webroot den Ordner vce/ mit fertigem menu.ipxe (deine URL eingesetzt),
# laedt wimboot (Windows-Kette) und optional den Debian-Netzinstaller, legt die
# Ablage-Ordner fuer ISOs an und schreibt eine nginx-Beispielkonfiguration.
#
#   sudo ./setup-server.sh --url http://mein-server.example [--root /srv/www] [--with-debian]
#
#   --url         Oeffentliche Basis-URL des Servers (so wie die Clients sie erreichen)
#   --root        Webroot-Verzeichnis (Default: /srv/www) - vce/ wird darunter angelegt
#   --with-debian Debian-12-Netzinstaller (Kernel+initrd, ~40 MB) gleich mitladen
set -euo pipefail
say(){ printf '%s\n' "$*"; }

URL=""; ROOT="/srv/www"; WITH_DEBIAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url)  URL="${2:?}"; shift 2 ;;
    --root) ROOT="${2:?}"; shift 2 ;;
    --with-debian) WITH_DEBIAN=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) say "Unbekannte Option: $1"; exit 1 ;;
  esac
done
[ -n "$URL" ] || { say "!! --url fehlt.  Beispiel: ./setup-server.sh --url http://mein-server.example"; exit 1; }
URL="${URL%/}"
V="$ROOT/vce"

say "== VCE-Server einrichten =="
say "Webroot: $ROOT   Basis-URL: $URL"
mkdir -p "$V" "$V/win11/media" "$V/ubuntu" "$V/debian" "$V/freebsd"

# 1) wimboot (Windows-Bootkette) - offizielles Release
say "- wimboot wird geladen"
curl -fsSL -L "https://github.com/ipxe/wimboot/releases/latest/download/wimboot" -o "$V/wimboot"
[ "$(wc -c < "$V/wimboot")" -gt 40000 ] || { say "!! wimboot-Download defekt"; exit 1; }

# 2) optional: Debian-Netzinstaller (einzige Quelle, die klein genug zum Mitladen ist)
if [ "$WITH_DEBIAN" = 1 ]; then
  say "- Debian-12-Netzinstaller wird geladen (~40 MB)"
  dbase="https://deb.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/debian-installer/amd64"
  curl -fsSL "$dbase/linux"     -o "$V/debian/linux"
  curl -fsSL "$dbase/initrd.gz" -o "$V/debian/initrd.gz"
fi

# 3) menu.ipxe mit eingesetzter URL erzeugen
say "- menu.ipxe wird erzeugt"
cat > "$V/menu.ipxe" <<EOF
#!ipxe
set base $URL/vce

:start
menu VCE - Betriebssystem installieren
item --gap --           == Installer ==
item win11              Windows 11 (wimboot)
item ubuntu             Ubuntu 24.04 (Live-ISO)
item debian             Debian 12 (Netzinstaller)
item freebsd            FreeBSD 14 (bootonly)
item --gap --           == Sonstiges ==
item macos_hint         macOS  (eigener OpenCore-Stick)
item shell              iPXE-Shell (Experten)
item reboot             Neustart
choose sel || goto start
goto \${sel}

:win11
kernel \${base}/wimboot
initrd \${base}/win11/media/Boot/BCD          BCD
initrd \${base}/win11/media/Boot/boot.sdi     boot.sdi
initrd \${base}/win11/media/sources/boot.wim  boot.wim
boot || goto failed

:ubuntu
kernel \${base}/ubuntu/vmlinuz initrd=initrd ip=dhcp url=\${base}/ubuntu/ubuntu.iso ---
initrd \${base}/ubuntu/initrd
boot || goto failed

:debian
kernel \${base}/debian/linux initrd=initrd.gz
initrd \${base}/debian/initrd.gz
boot || goto failed

:freebsd
sanboot \${base}/freebsd/freebsd-bootonly.iso || goto failed

:macos_hint
echo macOS wird nicht uebers Netz installiert (Apple-Signaturkette).
echo Dafuer den OpenCore-USB-Stick des macOS-Projekts nutzen.
prompt Taste druecken fuer zurueck ...
goto start

:shell
shell
goto start

:reboot
reboot

:failed
echo Boot fehlgeschlagen - zurueck zum Menue.
prompt Taste druecken ...
goto start
EOF

# 4) nginx-Beispielkonfiguration daneben legen
cat > "$ROOT/vce-nginx.conf.example" <<EOF
server {
    listen 80;
    server_name _;
    root $ROOT;
    location /vce/ { autoindex on; }
}
EOF

# 5) Ablage-Hinweise
cat > "$V/BEFUELLEN.txt" <<EOF
Noch zu befuellen (ISOs sind zu gross zum Automatisieren):

win11/media/   -> Inhalt der Windows-11-ISO hierher ENTPACKEN (Boot/, sources/, ...)
ubuntu/        -> vmlinuz + initrd (aus der ISO, Ordner casper/) und die ISO als ubuntu.iso
freebsd/       -> FreeBSD-…-bootonly.iso als freebsd-bootonly.iso
debian/        -> $( [ "$WITH_DEBIAN" = 1 ] && echo "FERTIG (linux + initrd.gz liegen bereit)" || echo "linux + initrd.gz (oder setup-server.sh --with-debian erneut ausfuehren)" )

Test vom Client:  curl -I $URL/vce/menu.ipxe   -> muss 200 liefern
EOF

say ""
say "== FERTIG: $V"
say "   - menu.ipxe zeigt auf $URL/vce"
say "   - nginx-Beispiel: $ROOT/vce-nginx.conf.example"
say "   - Was noch fehlt steht in: $V/BEFUELLEN.txt"
say "   Test: curl -I $URL/vce/menu.ipxe"

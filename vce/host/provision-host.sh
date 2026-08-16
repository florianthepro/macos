#!/usr/bin/env bash
# provision-host.sh - macht aus einem minimalen Debian 12/13 den VCE-Host.
# Installiert KVM/QEMU + OVMF, legt die VCE-Verzeichnisse an, installiert das
# VCE-Menue und laesst Konsole 1 direkt ins Menue booten.
#
#   sudo ./provision-host.sh http://mein-server.example
#
# Wird auch vom Preseed der automatischen Installation aufgerufen.
set -euo pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte als root:  sudo $0 <server-url>"; exit 1; }
SERVER="${1:-}"
[ -n "$SERVER" ] || { say "Aufruf: $0 http://mein-server.example"; exit 1; }
SERVER="${SERVER%/}"

say "== VCE-Host wird eingerichtet (Server: $SERVER) =="

# 1) Pakete: KVM/QEMU, virtuelles EFI (OVMF), TUI, Werkzeuge
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-system-x86 qemu-utils ovmf dialog curl ca-certificates >/dev/null
say "- QEMU/KVM + OVMF installiert"

# 2) VCE-Verzeichnisse + Konfiguration
mkdir -p /var/lib/vce/disks /var/lib/vce/isos /var/lib/vce/nvram /etc/vce
printf 'SERVER=%s\n' "$SERVER" > /etc/vce/vce.conf
say "- Verzeichnisse unter /var/lib/vce angelegt"

# 3) VCE-Menue installieren (lokale Kopie bevorzugt, sonst vom Server)
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -f "$here/vce-menu.sh" ]; then
  install -m 0755 "$here/vce-menu.sh" /usr/local/bin/vce-menu
else
  curl -fsSL "$SERVER/vce/host/vce-menu.sh" -o /usr/local/bin/vce-menu
  chmod 0755 /usr/local/bin/vce-menu
fi
bash -n /usr/local/bin/vce-menu || { say "!! vce-menu fehlerhaft"; exit 1; }
say "- VCE-Menue installiert (/usr/local/bin/vce-menu)"

# 4) Konsole 1 bootet direkt ins Menue (root-Autologin auf tty1 + Menue-Start)
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF
cat > /root/.bash_profile <<'EOF'
# VCE: auf Konsole 1 direkt ins Menue (Shell bleibt ueber Menuepunkt erreichbar)
if [ "$(tty)" = "/dev/tty1" ] && [ -x /usr/local/bin/vce-menu ]; then
  exec /usr/local/bin/vce-menu
fi
EOF
systemctl daemon-reload
say "- Konsole 1 startet kuenftig direkt das VCE-Menue"

# 5) KVM-Verfuegbarkeit pruefen (nur Hinweis - Provisionierung schlaegt nicht fehl)
if [ -e /dev/kvm ]; then say "- KVM aktiv (/dev/kvm vorhanden)"
else say "!! /dev/kvm fehlt: VT-x/AMD-V im BIOS aktivieren - VMs laufen sonst nur langsam (TCG)."; fi

say ""
say "== FERTIG. Neustart -> die Maschine bootet ins VCE-Menue."

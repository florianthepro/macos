#!/bin/bash
# camera.command - Interne Kamera unter macOS aktivieren. Die Kamera braucht keinen Treiber
# (UVC ist in macOS eingebaut) - sie muss nur am USB enumerieren. Fehlt sie, ist ihr interner
# Port nicht gemappt: dann uebernimmt usb-fix.command das (generische USB-Portmap). Sicher.
#   sudo bash camera.command
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
BASE="https://raw.githubusercontent.com/florianthepro/macos/main"

say "Voraussetzung: BIOS (F1) Security > I/O Port Access > Integrated Camera = On,"
say "und der ThinkShutter-Schieber offen (kein oranger Punkt)."
say ""

USB="$(system_profiler SPUSBDataType 2>/dev/null)"
if printf '%s' "$USB" | grep -qiE 'camera|bison|chicony|sunplus|azurewave|0x5986|0x04f2|0x13d3|0x2b7e|0x1bcf'; then
  say ">> Kamera ist am USB sichtbar. In Photo Booth testen. Schwarzes Bild? ThinkShutter oeffnen. Fertig."
  exit 0
fi

say "Kamera ist NICHT am USB - der interne Port ist nicht gemappt."
say "-> usb-fix.command baut jetzt die USB-Portmap (interne Ports als Typ 255) und startet neu."
say ""
if curl -fsSL "$BASE/scripts/usb-fix.command" -o /tmp/usb-fix.command; then
  exec bash /tmp/usb-fix.command
else
  say "!! Download von usb-fix.command fehlgeschlagen (Internet?)."
  say "   Manuell:  curl -fsSL \"$BASE/scripts/usb-fix.command\" -o /tmp/usb-fix.command && sudo bash /tmp/usb-fix.command"
  exit 1
fi

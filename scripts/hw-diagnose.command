#!/bin/bash
# hw-diagnose.command - Liest nur aus (kein sudo, aendert nichts) und sagt dir pro Geraet,
# WORAN es liegt und welchen naechsten Schritt du brauchst: Kamera, Bluetooth, USB-Ports.
# Doppelklick oder:  bash hw-diagnose.command
say(){ printf '%s\n' "$*"; }
hr(){ say "------------------------------------------------------------"; }

USB="$(system_profiler SPUSBDataType 2>/dev/null)"
LOADED="$( (kmutil showloaded 2>/dev/null || kextstat 2>/dev/null) )"

# ---- Aktuelle boot-args aus dem NVRAM lesen
BA="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"

# =========================================================== BLUETOOTH
hr; say "== BLUETOOTH =="
if printf '%s' "$USB" | grep -qiE '0x8087|Bluetooth USB Host'; then
  BT_USB=1; say "USB-Funkmodul (Intel 8087):  GEFUNDEN am USB-Bus"
else
  BT_USB=0; say "USB-Funkmodul (Intel 8087):  NICHT gefunden am USB-Bus"
fi
for k in Lilu IntelBluetoothFirmware IntelBTPatcher BlueToolFixup; do
  if printf '%s' "$LOADED" | grep -qi "$k"; then say "  Kext geladen: $k  = ja"; else say "  Kext geladen: $k  = NEIN"; fi
done
case "$BA" in *btlfxallowanyaddr*) say "  boot-arg -btlfxallowanyaddr: gesetzt" ;; *) say "  boot-arg -btlfxallowanyaddr: FEHLT" ;; esac
BTINFO="$(system_profiler SPBluetoothDataType 2>/dev/null)"
if printf '%s' "$BTINFO" | grep -qiE 'Address:'; then
  say "  BT-Controller-Adresse: $(printf '%s' "$BTINFO" | grep -iE 'Address:' | head -n1 | sed 's/^[[:space:]]*//')"
fi
say "> EMPFEHLUNG:"
if [ "$BT_USB" = 1 ]; then
  case "$BA" in
    *btlfxallowanyaddr*) say "  BT-Modul ist sichtbar + boot-arg gesetzt. Wenn BT trotzdem aus:"
                         say "  Fn+F8 (Funk an?) und in den BT-Einstellungen kurz aus/ein. Sonst melde dich." ;;
    *) say "  BT-Modul ist am USB SICHTBAR -> kein USB-Mapping noetig!"
       say "  Es fehlt nur der boot-arg. Fuehre aus:  sudo bash bt-anyaddr.command" ;;
  esac
else
  say "  BT-Modul erscheint NICHT am USB. Erst pruefen: BIOS (F1) -> Security ->"
  say "  I/O Port Access -> Bluetooth = On, und Fn+F8 (Funk an). Wenn es dann"
  say "  immer noch fehlt, ist USB-Port-Mapping noetig (siehe README / usb-map)."
fi

# =========================================================== KAMERA
hr; say "== KAMERA =="
CAMLINE="$(printf '%s' "$USB" | grep -iE 'camera|bison|chicony|sunplus|azurewave|0x5986|0x04f2|0x13d3|0x2b7e' | head -n1 | sed 's/^[[:space:]]*//')"
if [ -n "$CAMLINE" ]; then
  CAM_USB=1; say "Kamera am USB-Bus:  GEFUNDEN  ($CAMLINE)"
else
  CAM_USB=0; say "Kamera am USB-Bus:  NICHT gefunden"
fi
CAMDATA="$(system_profiler SPCameraDataType 2>/dev/null | grep -vE '^$|Camera:$' | head -n3)"
[ -n "$CAMDATA" ] && say "SPCameraDataType meldet:" && printf '%s\n' "$CAMDATA"
say "> EMPFEHLUNG:"
if [ "$CAM_USB" = 1 ]; then
  say "  Kamera ist am USB sichtbar. Kein Bild? ThinkShutter-Schieber oeffnen"
  say "  (kein oranger Punkt) und in Photo Booth testen."
else
  say "  Kamera fehlt am USB. Erst: BIOS (F1) -> Security -> I/O Port Access ->"
  say "  Integrated Camera = On, ThinkShutter auf. Wenn dann immer noch weg:"
  say "  USB-Port-Mapping noetig (siehe README / usb-map)."
fi

# =========================================================== USB-PORT-UEBERBLICK
hr; say "== USB-PORTS (Limit: 15 Personalities pro Controller) =="
PORTS="$(ioreg -p IOUSB 2>/dev/null | grep -cE '@[0-9]')"
say "Sichtbare USB-Knoten (grob): ${PORTS:-?}"
say "Fehlen Kamera UND Bluetooth am USB, obwohl im BIOS aktiv, ist das das"
say "typische 15-Port-Limit -> USB-Mapping (USBMap.command) loest beide zugleich."
hr
say "Kopiere diese Ausgabe und schicke sie mir - dann sage ich dir den exakten Fix."

#!/bin/bash
# usb-test.command - LIEST NUR AUS (aendert nichts). Sammelt den kompletten Zustand, damit klar
# wird, warum Kamera/BT nicht erscheinen: enumerierte Ports, ob der RHUB-Reset in der config steht
# und aktiv ist, ob OpenCore ihn anwendet (Log), die RHUB-Pfade und den DSDT-Ausschnitt des RHUB.
# Braucht sudo (interne EFI mounten + config lesen). Gibt am Ende alles gebuendelt aus - bitte
# komplett kopieren und schicken.
set -o pipefail
say(){ printf '%s\n' "$*"; }
hr(){ say "======================================================================"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy
U="${SUDO_USER:-$USER}"; HOMEUSR="$(eval echo ~"$U")"

# interne EFI mounten
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; ACPIDIR="$mp/EFI/OC/ACPI"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }

hr; say "USB-TEST / ZUSTANDSBERICHT  (EFI: $mp)"; hr

say ""; say "### 1) KAMERA / BLUETOOTH am USB"
USB="$(system_profiler SPUSBDataType 2>/dev/null)"
printf '%s' "$USB" | grep -qiE 'camera|bison|chicony|sunplus|azurewave|0x5986|0x04f2|0x13d3|0x2b7e|0x1bcf' && say "Kamera: GEFUNDEN" || say "Kamera: fehlt"
printf '%s' "$USB" | grep -qiE '0x8087|Bluetooth USB Host' && say "Bluetooth(8087): GEFUNDEN" || say "Bluetooth(8087): fehlt"
say "USB-Geraete gesamt (Product ID): $(printf '%s' "$USB" | grep -c 'Product ID:')"

say ""; say "### 2) ENUMERIERTE XHCI-PORTS (macOS)"
ioreg -rc AppleUSB20XHCIPort -w0 2>/dev/null | grep -E '"?(port|PortType|UsbConnector)"?' >/dev/null
ioreg -w0 -rc AppleUSBHostPort 2>/dev/null | grep -c AppleUSBHostPort | sed 's/^/AppleUSBHostPort-Objekte: /'
ioreg -p IOService -n XHC@14 -w0 -r 2>/dev/null | grep -oE '[HS]S[0-9][0-9]|SS[0-9][0-9]' | sort -u | tr '\n' ' '; say ""

say ""; say "### 3) RHUB-ACPI-Pfade (USBMap)"
if [ -d "$HOMEUSR/USBMap" ]; then
  (cd "$HOMEUSR/USBMap" && printf 'q\n' | sudo -u "$U" python3 USBMap.py 2>/dev/null) | grep -E 'RHUB @|XHC@' | sed 's/^/  /'
else say "  (USBMap nicht vorhanden - uebersprungen)"; fi

say ""; say "### 4) config.plist -> ACPI:Add (SSDTs)"
$PB -c "Print :ACPI:Add" "$CFG" 2>/dev/null | grep -E 'Path|Comment|Enabled' | sed 's/^/  /'

say ""; say "### 5) config.plist -> ACPI:Patch (Renames)"
$PB -c "Print :ACPI:Patch" "$CFG" 2>/dev/null | grep -E 'Comment|Base|Enabled|Count|Find|Replace|TableSignature' | sed 's/^/  /'

say ""; say "### 6) Dateien in EFI/OC/ACPI"
ls -1 "$ACPIDIR" 2>/dev/null | sed 's/^/  /'

say ""; say "### 7) Kernel:Quirks:XhciPortLimit"
$PB -c "Print :Kernel:Quirks:XhciPortLimit" "$CFG" 2>/dev/null | sed 's/^/  /'

say ""; say "### 8) OpenCore-Log: ACPI/SSDT/Patch-Zeilen (falls Log vorhanden)"
log="$(ls -t "$mp"/opencore-*.txt "$mp"/EFI/opencore-*.txt 2>/dev/null | head -n1)"
if [ -n "$log" ]; then
  say "  Log: $log"
  grep -iE 'OCA:|SSDT|patch|RHUB|_STA|XSTA|acpi' "$log" 2>/dev/null | head -n 40 | sed 's/^/  /'
else
  say "  (kein opencore-*.txt gefunden - Datei-Logging evtl. aus; Misc>Debug>Target)"
fi

hr; say "FERTIG - bitte den GESAMTEN Text oben kopieren und mir schicken."; hr

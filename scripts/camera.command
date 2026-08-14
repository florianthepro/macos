#!/bin/bash
# camera.command - Interne Kamera unter macOS aktivieren. Generisch fuer alle ThinkPad-/Lenovo-
# Modelle: erkennt die RHUB-ACPI-Pfade automatisch und macht versteckte interne USB-Ports sichtbar
# (RHUB-Reset-SSDT + Base-scoped _STA->XSTA-Rename). Kamera braucht danach keinen Treiber (UVC ist
# in macOS eingebaut). Sicher: Backup + plutil-Pruefung, bei Fehler automatischer Rueckbau.
#   sudo bash camera.command
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy

say "Voraussetzung: im BIOS (F1) Security > I/O Port Access > Integrated Camera = On,"
say "und der ThinkShutter-Schieber offen (kein oranger Punkt)."
say ""

# --- schon sichtbar? -------------------------------------------------------------
USB="$(system_profiler SPUSBDataType 2>/dev/null)"
if printf '%s' "$USB" | grep -qiE 'camera|bison|chicony|sunplus|azurewave|0x5986|0x04f2|0x13d3|0x2b7e|0x1bcf'; then
  say ">> Kamera ist am USB sichtbar. In Photo Booth testen."
  say "   Schwarzes Bild? ThinkShutter oeffnen. Fertig."
  exit 0
fi
say "Kamera ist NICHT am USB - interne Ports muessen sichtbar gemacht werden (Reveal)."

# --- interne EFI mounten ---------------------------------------------------------
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; ACPIDIR="$mp/EFI/OC/ACPI"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }
[ -d "$ACPIDIR" ] || mkdir -p "$ACPIDIR"
say "EFI: $mp"

# --- generischer Reveal ----------------------------------------------------------
# echo: already | applied | failed | guide
ensure_reveal(){
  local CFG="$1" ACPIDIR="$2"
  if $PB -c "Print :ACPI:Patch" "$CFG" 2>/dev/null | grep -q "RHUB reveal"; then echo already; return 0; fi
  local U H IASL paths dsl aml STA XSTA i p bp
  U="${SUDO_USER:-$USER}"; H="$(eval echo ~"$U")"; IASL="$H/iasl"
  [ -x "$IASL" ] || { curl -fsSL "https://raw.githubusercontent.com/acidanthera/MaciASL/master/Dist/iasl-stable" -o "$IASL" 2>/dev/null && chmod +x "$IASL"; }
  [ -x "$IASL" ] || { echo guide; return 0; }
  [ -d "$H/USBMap" ] || sudo -u "$U" git clone https://github.com/corpnewt/USBMap "$H/USBMap" >/dev/null 2>&1
  paths="$( (cd "$H/USBMap" 2>/dev/null && printf 'q\n' | sudo -u "$U" python3 USBMap.py 2>/dev/null) | grep -oE 'RHUB @ [^ ]+' | awk '{print $3}' | sort -u )"
  [ -n "$paths" ] || { echo guide; return 0; }
  dsl=/tmp/SSDT-USB-Reset.dsl; aml=/tmp/SSDT-USB-Reset.aml
  { echo 'DefinitionBlock ("", "SSDT", 2, "OCLT", "RHBRST", 0x00001000)'; echo '{'
    for p in $paths; do
      echo "    External ($p, DeviceObj)"
      echo "    Scope ($p) { Method (_STA, 0, NotSerialized) { If (_OSI (\"Darwin\")) { Return (Zero) } Else { Return (0x0F) } } }"
    done; echo '}'; } > "$dsl"
  rm -f "$aml"; "$IASL" "$dsl" >/dev/null 2>&1
  [ -f "$aml" ] || { echo guide; return 0; }
  cp "$CFG" "$CFG.revealbak"
  cp "$aml" "$ACPIDIR/SSDT-USB-Reset.aml"
  if ! $PB -c "Print :ACPI:Add" "$CFG" 2>/dev/null | grep -q "Path = SSDT-USB-Reset.aml"; then
    /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
    i="$(/usr/bin/plutil -extract ACPI.Add raw -o - "$CFG" 2>/dev/null)"; case "$i" in ''|*[!0-9]*) i="";; esac
    [ -n "$i" ] && $PB -c "Add :ACPI:Add:$i dict" -c "Add :ACPI:Add:$i:Comment string SSDT-USB-Reset" \
      -c "Add :ACPI:Add:$i:Enabled bool true" -c "Add :ACPI:Add:$i:Path string SSDT-USB-Reset.aml" "$CFG"
  fi
  STA="$(printf '_STA'|base64)"; XSTA="$(printf 'XSTA'|base64)"
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><array>'
    for p in $paths; do case "$p" in \\*) bp="$p";; *) bp="\\$p";; esac
      echo "<dict><key>Base</key><string>$bp</string><key>BaseSkip</key><integer>0</integer><key>Comment</key><string>RHUB reveal: _STA to XSTA</string><key>Count</key><integer>1</integer><key>Enabled</key><true/><key>Find</key><data>$STA</data><key>Limit</key><integer>0</integer><key>Mask</key><data></data><key>OemTableId</key><data></data><key>Replace</key><data>$XSTA</data><key>ReplaceMask</key><data></data><key>Skip</key><integer>0</integer><key>TableLength</key><integer>0</integer><key>TableSignature</key><data></data></dict>"
    done; echo '</array></plist>'; } > /tmp/reveal_patches.plist
  $PB -c "Print :ACPI:Patch" "$CFG" >/dev/null 2>&1 || $PB -c "Add :ACPI:Patch array" "$CFG" 2>/dev/null
  $PB -c "Merge /tmp/reveal_patches.plist :ACPI:Patch" "$CFG" 2>/dev/null
  /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
  if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then echo applied; else cp "$CFG.revealbak" "$CFG"; echo failed; fi
}

state="$(ensure_reveal "$CFG" "$ACPIDIR")"
say ""
case "$state" in
  applied) say ">> Reveal erzeugt und eingetragen (config.plist gueltig)."
           say "   NEU STARTEN, dann camera.command nochmal - dann sollte die Kamera da sein." ;;
  already) say ">> Reveal ist bereits aktiv, Kamera aber (noch) nicht sichtbar."
           say "   1) Erst NEU STARTEN und pruefen."
           say "   2) Bleibt sie weg: der Controller hat >15 Ports -> einmaliges USB-Mapping"
           say "      (USBMap -> P -> Kamera als Typ 255 behalten, dann usb-map-install.command)." ;;
  failed)  say "!! Automatik fehlgeschlagen - config.plist wurde unveraendert zurueckgesetzt."
           say "   Manuell: USBMap -> H (SSDT), dann ssdt-install.command." ;;
  guide)   say ">> Konnte die RHUB-Pfade nicht automatisch ermitteln."
           say "   Manuell: cd ~/USBMap && ./USBMap.command -> H (Generate ACPI To Reset RHUBs),"
           say "   dann ssdt-install.command. Danach camera.command erneut." ;;
esac

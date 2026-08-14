#!/bin/bash
# usb-map-install.command - Installiert eine mit USBMap gebaute USBMap.kext SICHER in die
# interne EFI: Backup + Eintrag in config.plist (codeless) + XhciPortLimit=false + Validierung,
# bei Fehler automatischer Rueckbau. Entfernt die Discovery-Hilfskext (USBMapDummy) mit.
#   sudo bash usb-map-install.command [/pfad/zur/USBMap.kext]
# Ohne Pfad wird an den ueblichen Stellen gesucht (~/USBMap, ~/Downloads, ~/Desktop).
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\" [pfad/USBMap.kext]"; exit 1; }

# 1) USBMap.kext finden
KEXT="$1"
if [ -z "$KEXT" ]; then
  for d in "$HOME" "$HOME/USBMap" "$HOME/Downloads" "$HOME/Desktop" /Users/*/USBMap; do
    c="$(find "$d" -maxdepth 3 -type d -name 'USBMap.kext' 2>/dev/null | head -n1)"
    [ -n "$c" ] && { KEXT="$c"; break; }
  done
fi
[ -n "$KEXT" ] && [ -d "$KEXT" ] || { say "!! USBMap.kext nicht gefunden. Pfad als Argument angeben:"; say "   sudo bash \"$0\" ~/USBMap/USBMap.kext"; exit 1; }
[ -f "$KEXT/Contents/Info.plist" ] || { say "!! $KEXT enthaelt keine Info.plist - falscher Ordner?"; exit 1; }
say "USBMap.kext: $KEXT"

# 2) Interne EFI mounten + config.plist
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI-Partition nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; KEXTS="$mp/EFI/OC/Kexts"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden ($CFG)."; exit 1; }
say "EFI: $mp"
cp "$CFG" "$CFG.usbbak" || { say "Backup fehlgeschlagen"; exit 1; }
PB=/usr/libexec/PlistBuddy

# 3) Kext kopieren, Discovery-Dummy entfernen
rm -rf "$KEXTS/USBMap.kext"; cp -R "$KEXT" "$KEXTS/USBMap.kext"
rm -rf "$KEXTS/USBMapDummy.kext"
say "- USBMap.kext kopiert, USBMapDummy.kext entfernt."

# 4) In config.plist eintragen (codeless -> ExecutablePath leer), Dublettenschutz
if $PB -c "Print :Kernel:Add" "$CFG" 2>/dev/null | grep -q "BundlePath = USBMap.kext\$"; then
  say "- USBMap.kext war schon in der config.plist (ok)."
else
  # config.plist muss XML sein, damit plutil -extract sicher zaehlt
  /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
  i="$(/usr/bin/plutil -extract Kernel.Add raw -o - "$CFG" 2>/dev/null)"
  case "$i" in ''|*[!0-9]*) say "!! Index konnte nicht bestimmt werden."; cp "$CFG.usbbak" "$CFG"; exit 1;; esac
  $PB \
    -c "Add :Kernel:Add:$i dict" \
    -c "Add :Kernel:Add:$i:Arch string x86_64" \
    -c "Add :Kernel:Add:$i:BundlePath string USBMap.kext" \
    -c "Add :Kernel:Add:$i:Comment string USB port map" \
    -c "Add :Kernel:Add:$i:Enabled bool true" \
    -c "Add :Kernel:Add:$i:ExecutablePath string " \
    -c "Add :Kernel:Add:$i:MaxKernel string " \
    -c "Add :Kernel:Add:$i:MinKernel string " \
    -c "Add :Kernel:Add:$i:PlistPath string Contents/Info.plist" \
    "$CFG" && say "- USBMap.kext in config.plist eingetragen (Index $i)."
fi

# 5) XhciPortLimit ausschalten (unter Ventura unzuverlaessig; mit Map nicht noetig)
$PB -c "Set :Kernel:Quirks:XhciPortLimit false" "$CFG" 2>/dev/null \
  && say "- XhciPortLimit = false."

# 6) Validieren -> bei Fehler Backup zurueck
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
  say ""
  say "== OK. Bitte NEU STARTEN."
  say "   Danach in 'Ueber diesen Mac > Weitere Infos > USB' pruefen, ob Kamera"
  say "   und Bluetooth erscheinen. Backup: $CFG.usbbak"
else
  say "!! config.plist wurde ungueltig -> Backup wird zurueckgespielt (keine Aenderung)."
  cp "$CFG.usbbak" "$CFG"; exit 1
fi

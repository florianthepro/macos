#!/bin/bash
# bt-anyaddr.command - Schneller Bluetooth-Fix, WENN das Intel-8087-Modul bereits am USB
# sichtbar ist (siehe hw-diagnose.command), BT aber trotzdem aus bleibt. Ursache ist dann
# meist eine NULL-Adresse des Controllers unter Ventura; der boot-arg -btlfxallowanyaddr
# laesst BlueToolFixup den Controller trotzdem akzeptieren.
# Sicher: Backup + plutil-Pruefung, bei Fehler automatischer Rueckbau. Mit sudo starten.
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }

# Interne EFI mounten + config.plist finden
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI-Partition nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden ($CFG)."; exit 1; }
say "EFI: $mp"
cp "$CFG" "$CFG.btbak" || { say "Backup fehlgeschlagen"; exit 1; }
PB=/usr/libexec/PlistBuddy
BA=7C436110-AB2A-4BBB-A880-FE41995C9F82

cur="$($PB -c "Print :NVRAM:Add:$BA:boot-args" "$CFG" 2>/dev/null)"
case "$cur" in
  *btlfxallowanyaddr*) say "- boot-arg war schon gesetzt (ok)." ;;
  *) newv="-btlfxallowanyaddr${cur:+ $cur}"
     $PB -c "Set :NVRAM:Add:$BA:boot-args $newv" "$CFG" 2>/dev/null \
       || $PB -c "Add :NVRAM:Add:$BA:boot-args string -btlfxallowanyaddr" "$CFG" 2>/dev/null
     say "- boot-arg -btlfxallowanyaddr ergaenzt." ;;
esac

# Validieren -> bei Fehler Backup zurueck
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
  say ""
  say "== OK. Bitte NEU STARTEN. Danach sollte Bluetooth erscheinen."
  say "   Falls nicht: hw-diagnose.command erneut laufen lassen und Ausgabe schicken."
  say "   Backup: $CFG.btbak"
else
  say "!! config.plist wurde ungueltig -> Backup wird zurueckgespielt."
  cp "$CFG.btbak" "$CFG"; exit 1
fi

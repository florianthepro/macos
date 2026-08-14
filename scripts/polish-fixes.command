#!/bin/bash
# polish-fixes.command - Feinschliff fuers bereits installierte System:
#   1) Boot-Fehler "OCS: No schema for LegacyEnable ..." entfernen
#   2) OpenCore-/Recovery-Auswahlbildschirm ("Splash") gar nicht mehr zeigen -> direkt durchbooten
#   3) Sauberer Boot (Apple-Logo statt Verbose-Text)
#   4) Tastatur: die Taste "</>/|" macht wieder "<>|" statt "^/°" (ISO-Swap), bleibt nach Neustart
#
# Sicher: Backup der config.plist + Validierung; bei Fehler automatischer Rueckbau.
# Backup bleibt als config.plist.polishbak liegen. Mit sudo ausfuehren:  sudo bash "$0"
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }

# ------------------------------------------------------------------ 1. Interne EFI + config.plist
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI-Partition nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden ($CFG)."; exit 1; }
say "EFI: $mp"
cp "$CFG" "$CFG.polishbak" || { say "Backup fehlgeschlagen"; exit 1; }
PB=/usr/libexec/PlistBuddy

# ------------------------------------------------------------------ 2. LegacyEnable-Fehler weg
# Der veraltete NVRAM-Schluessel loest bei jedem Boot "OCS: No schema for LegacyEnable" aus.
$PB -c "Delete :NVRAM:LegacyEnable" "$CFG" 2>/dev/null && say "- LegacyEnable entfernt (Boot-Fehler weg)." \
  || say "- LegacyEnable war nicht vorhanden (ok)."

# ------------------------------------------------------------------ 3. Splash/Picker aus + sauberer Boot
$PB -c "Set :Misc:Boot:ShowPicker false" "$CFG" 2>/dev/null \
  || $PB -c "Add :Misc:Boot:ShowPicker bool false" "$CFG" 2>/dev/null
$PB -c "Set :Misc:Boot:Timeout 2" "$CFG" 2>/dev/null
$PB -c "Set :Misc:Debug:Target 65" "$CFG" 2>/dev/null   # OpenCore-Log als Datei, nicht auf den Schirm
say "- Auswahlbildschirm aus (bootet direkt durch)."

# Verbose-Text aus den boot-args nehmen (alcid=... u. a. bleiben erhalten)
BA=7C436110-AB2A-4BBB-A880-FE41995C9F82
cur="$($PB -c "Print :NVRAM:Add:$BA:boot-args" "$CFG" 2>/dev/null)"
if [ -n "$cur" ]; then
  new="$(printf '%s\n' "$cur" | tr ' ' '\n' \
        | grep -vx -e '-v' -e 'keepsyms=1' -e 'debug=0x100' -e 'debug=0x144' \
        | paste -sd' ' - | sed 's/^ *//;s/ *$//')"
  $PB -c "Set :NVRAM:Add:$BA:boot-args $new" "$CFG" 2>/dev/null
  say "- Sauberer Boot (Apple-Logo). boot-args: ${new:-<leer>}"
fi

# ------------------------------------------------------------------ 4. config.plist validieren
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
  say "- config.plist ist gueltig."
else
  say "!! config.plist wurde ungueltig -> Backup wird zurueckgespielt (keine Aenderung an der EFI)."
  cp "$CFG.polishbak" "$CFG"
  say "   Tastatur-Fix wird trotzdem gesetzt."
fi

# ------------------------------------------------------------------ 5. Tastatur: ISO-Swap "<>|" <-> "^°"
# macOS vertauscht auf PC-/Apple-ISO-Tastaturen die Taste links neben der Linksshift (HID 0x64,
# soll "<>|") mit der Taste oben links (HID 0x35, soll "^°"). Der Swap dreht beide zurueck.
# Gilt fuer interne, externe Windows- UND Apple-Tastaturen. RunAtLoad -> bleibt nach Neustart.
KB_MAP='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000064,"HIDKeyboardModifierMappingDst":0x700000035},{"HIDKeyboardModifierMappingSrc":0x700000035,"HIDKeyboardModifierMappingDst":0x700000064}]}'
DAEMON=/Library/LaunchDaemons/com.local.keyboard-iso-fix.plist
cat > "$DAEMON" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.local.keyboard-iso-fix</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/hidutil</string>
        <string>property</string>
        <string>--set</string>
        <string>$KB_MAP</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
chmod 644 "$DAEMON"; chown root:wheel "$DAEMON"
launchctl bootout system "$DAEMON" 2>/dev/null
launchctl bootstrap system "$DAEMON" 2>/dev/null || launchctl load "$DAEMON" 2>/dev/null
/usr/bin/hidutil property --set "$KB_MAP" >/dev/null 2>&1 \
  && say "- Tastatur: Taste \"<>|\" macht wieder <>| (sofort aktiv, bleibt nach Neustart)." \
  || say "- Tastatur-Mapping gesetzt (wird beim naechsten Login/Neustart aktiv)."

say ""
say "== FERTIG. Bitte NEU STARTEN."
say "   Falls du den Auswahlbildschirm doch mal brauchst: vom USB-Stick booten"
say "   (der zeigt ihn weiter). Backup der Config: $CFG.polishbak"

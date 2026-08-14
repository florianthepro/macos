#!/bin/bash
# imessage.command - iMessage/FaceTime-Aktivierung vorbereiten. Setzt die ROM auf die echte
# MAC-Adresse des Netzwerkadapters (Apple-Empfehlung; bisher Zufallswert), zeigt Seriennummer/MLB
# zum Gegenpruefen und prueft, ob das Netz-Interface als "built-in" gilt (Voraussetzung).
# Sicher: Backup + plutil-Pruefung mit automatischem Rueckbau.  sudo bash imessage.command
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy

esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }
say "EFI: $mp"
cp "$CFG" "$CFG.imsgbak"

# 1) ROM = echte MAC des primaeren Interfaces (en0, sonst en1)
MAC=""
for ifc in en0 en1; do
  MAC="$(ifconfig "$ifc" 2>/dev/null | awk '/ether/{print $2; exit}')"
  [ -n "$MAC" ] && { IFACE="$ifc"; break; }
done
if [ -n "$MAC" ]; then
  HEX="$(printf '%s' "$MAC" | tr -d ':')"
  B64="$(printf '%s' "$HEX" | xxd -r -p | base64)"
  /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
  if /usr/bin/plutil -replace PlatformInfo.Generic.ROM -data "$B64" "$CFG" 2>/dev/null; then
    say "- ROM auf die MAC von $IFACE gesetzt ($MAC)."
  else
    say "- ROM konnte nicht gesetzt werden (uebersprungen)."
  fi
else
  say "- Keine MAC gefunden (WLAN aus?) - ROM unveraendert."
fi

# 2) Identitaet anzeigen (zum Gegenpruefen)
SER="$($PB -c "Print :PlatformInfo:Generic:SystemSerialNumber" "$CFG" 2>/dev/null)"
MLB="$($PB -c "Print :PlatformInfo:Generic:MLB" "$CFG" 2>/dev/null)"
SMB="$($PB -c "Print :PlatformInfo:Generic:SystemProductName" "$CFG" 2>/dev/null)"
say "- SMBIOS: ${SMB:-?}  Seriennummer: ${SER:-?}  MLB: ${MLB:-?}"

# 3) built-in-Pruefung des Netz-Interfaces (Apple verlangt ein eingebautes en0)
BI="$(ioreg -rc IONetworkInterface -l 2>/dev/null | awk '/"BSD Name" = "en0"/{f=1} f&&/IOBuiltin/{print; exit}')"
case "$BI" in
  *Yes*|*true*) say "- en0 ist als eingebaut (built-in) markiert: gut." ;;
  *) say "- HINWEIS: en0 wirkt NICHT als built-in markiert - falls die Anmeldung weiter"
     say "  scheitert, ist das der naechste Ansatzpunkt (bitte melden)." ;;
esac

# 4) Validieren
/usr/bin/plutil -lint "$CFG" >/dev/null 2>&1 || { say "!! config ungueltig -> Rueckbau."; cp "$CFG.imsgbak" "$CFG"; exit 1; }

say ""
say "== OK. Jetzt so aktivieren:"
say "   1. NEU STARTEN (damit die ROM greift)."
say "   2. Systemeinstellungen > Datum & Uhrzeit: automatisch stellen (Zeit muss stimmen)."
say "   3. In iMessage UND FaceTime ABMELDEN (falls angemeldet), dann NEU anmelden."
say "   4. Klappt es nicht sofort: 10 Minuten warten, nochmal versuchen."
say "   5. Kommt eine Meldung mit 'Kundencode'/'customer code': Apple-Support anrufen"
say "      und den Code nennen - Apple schaltet die Apple-ID dann einmalig frei"
say "      (normal bei neuen 'Geraeten', dauert 2 Minuten)."
say "   Seriennummer-Check (optional): https://checkcoverage.apple.com -> ${SER:-<Seriennummer>}"
say "   Backup: $CFG.imsgbak"

#!/bin/bash
# keyboard.command - Macht die KOMPLETTE deutsche ThinkPad-/Lenovo-Tastatur unter macOS richtig.
# Installiert das deutsche Windows/PC-Tastaturlayout (@ auf AltGr+Q, € [] {} \ | ~ usw. genau wie
# aufgedruckt) und entfernt den frueheren hidutil-Swap (das Layout uebernimmt <>| und ^° selbst -
# beides zusammen wuerde doppelt vertauschen). Generisch fuer alle deutschen ThinkPad-/Lenovo-Modelle.
#   Ausfuehren:  sudo bash keyboard.command
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
BASE="https://raw.githubusercontent.com/florianthepro/macos/claude/macos-usb-installer-exe-bfvxsy"

# 1) Frueheren hidutil-Swap restlos entfernen (Layout macht das jetzt komplett)
D=/Library/LaunchDaemons/com.local.keyboard-iso-fix.plist
if [ -f "$D" ]; then
  launchctl bootout system "$D" 2>/dev/null || launchctl unload "$D" 2>/dev/null
  rm -f "$D"
  say "- Frueheren Tastatur-Swap entfernt (Layout uebernimmt das)."
fi
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null 2>&1

# 2) Windows-Layout systemweit installieren
DEST="/Library/Keyboard Layouts"
mkdir -p "$DEST"
if curl -fsSL "$BASE/assets/keyboard/Windows-German.keylayout" -o "$DEST/Windows-German.keylayout"; then
  chmod 644 "$DEST/Windows-German.keylayout"
  # kurze Gueltigkeitspruefung (muss das @ auf AltGr+Q enthalten)
  if grep -q 'code="12" output="@"' "$DEST/Windows-German.keylayout"; then
    say "- Layout installiert: $DEST/Windows-German.keylayout"
  else
    say "!! Layout-Datei sieht unvollstaendig aus - Abbruch."; rm -f "$DEST/Windows-German.keylayout"; exit 1
  fi
else
  say "!! Download des Layouts fehlgeschlagen (Internet?)."; exit 1
fi

# 3) Anleitung zum Aktivieren
say ""
say "== FAST FERTIG - Layout noch auswaehlen:"
say "   Systemeinstellungen > Tastatur > Eingabequellen (Texteingabe) > '+'"
say "   > Deutsch > 'Deutsch - Windows (ThinkPad)' hinzufuegen."
say "   Das Apple-'Deutsch' danach entfernen, damit nur noch das Windows-Layout aktiv ist."
say "   Erscheint es nicht sofort: einmal ab- und wieder anmelden."
say ""
say "   Danach stimmt die ganze Tastatur: @ = AltGr+Q, die Taste \"<>|\" macht <>|,"
say "   \"^/°\" oben links, sowie € [] {} \\ | ~ ² ³ µ wie aufgedruckt."
say "   (Am Anmelde-/Sperrbildschirm nutzt macOS immer sein eigenes Layout - das ist normal.)"

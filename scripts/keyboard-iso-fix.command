#!/bin/bash
# keyboard-iso-fix.command - Sauberer, dauerhafter Tastatur-Fix OHNE Fremdsoftware.
# Entfernt zuerst den frueheren hidutil-Zwei-Tasten-Swap und laesst macOS die Tastatur
# dann als ISO erkennen. Danach stimmen ALLE Tasten (nicht nur "<>|"/"^°"), und zwar
# pro Tastatur getrennt: interne + externe Windows-Tastaturen als ISO, eine Apple-ANSI-
# Tastatur bleibt ANSI - alle gleichzeitig korrekt.
#   Ausfuehren:  bash keyboard-iso-fix.command   (fragt bei Bedarf nach dem Passwort)
say(){ printf '%s\n' "$*"; }

# 1) Frueheren globalen Swap restlos entfernen (sonst stapelt er sich auf die ISO-Zuordnung)
D=/Library/LaunchDaemons/com.local.keyboard-iso-fix.plist
if [ -f "$D" ]; then
  say "- Entferne den frueheren Tastatur-Swap ..."
  sudo launchctl bootout system "$D" 2>/dev/null || sudo launchctl unload "$D" 2>/dev/null
  sudo rm -f "$D"
fi
/usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null 2>&1
say "- Alter Swap entfernt, macOS-Standardzuordnung ist aktiv."

# 2) macOS die Tastatur als ISO erkennen lassen (Einrichtungsassistent)
say ""
say "- Oeffne den Tastatur-Einrichtungsassistenten ..."
open "/System/Library/CoreServices/Keyboard Setup Assistant.app" 2>/dev/null \
  || open -b com.apple.KeyboardSetupAssistant 2>/dev/null \
  || say "  (Assistent nicht gefunden - alternativ: Systemeinstellungen > Tastatur >"
say ""
say "   Im Assistenten:"
say "     1. 'Fortfahren'"
say "     2. die Taste unmittelbar RECHTS neben der linken Umschalt-/Shift-Taste druecken"
say "     3. das Bild 'ISO' (europaeisch, mit Extra-Taste neben Shift) waehlen -> 'Fertig'"
say ""
say "   -> Die Taste \"<>|\" macht danach wieder <>|, die Taste oben links wieder ^/°,"
say "      und alle uebrigen ISO-Tasten stimmen ebenfalls."
say "   -> Schliesst du spaeter eine weitere Windows-Tastatur an, den Assistenten dafuer"
say "      einmal wiederholen (jede physische Tastatur wird getrennt gemerkt)."
say ""
say "   Fehlt im Assistenten der Startknopf? Einmal ab-/anstecken, oder als Reset:"
say "     sudo rm /Library/Preferences/com.apple.keyboardtype.plist   und neu einloggen."
say ""
say "   WICHTIG: Als Eingabequelle muss 'Deutsch' gewaehlt sein"
say "   (Systemeinstellungen > Tastatur > Eingabequellen)."

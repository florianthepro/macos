#!/bin/bash
# offline-install.command - macOS offline installieren: EIN Kommando, keine Rueckfragen.
# Macht bewusst NUR zwei Dinge (ersetzt Festplattendienstprogramm + Installer-Klick):
#   1) interne Platte automatisch als APFS formatieren
#   2) macOS-Installation vom Stick starten (offline, kein Internet)
# Alles Weitere (OpenCore auf die interne Platte, Fixes) macht NACH der Installation
# start-me.command per Doppelklick. Bis dahin: Stick eingesteckt lassen und im Boot-Menue
# die Eintraege "macOS Installer" bzw. "Macintosh HD" waehlen.
# Optionales Argument: Zielplatte (/dev/diskN); sonst Auto-Erkennung.
set -o pipefail
say() { printf '%s\n' "$*"; }
say "== macOS Offline-Installer =="

# 1. Voll-Installer finden (neben dem Skript oder auf einer gemounteten Partition).
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
pkg="$here/InstallAssistant.pkg"
[ -f "$pkg" ] || pkg="$(find /Volumes -maxdepth 2 -name InstallAssistant.pkg -type f 2>/dev/null | head -n1)"
if [ ! -f "$pkg" ]; then
  say "!! InstallAssistant.pkg nicht gefunden."
  say "   Nur Sonoma/Sequoia: Datenpartition mounten:"
  say "     diskutil list physical ; mkdir /Volumes/DATA ; /sbin/mount_exfat /dev/diskXsY /Volumes/DATA"
  exit 1
fi
say "Installer: $pkg"

# 2. Zielplatte: Argument, sonst genau eine interne, nicht-entfernbare physische Platte.
if [ -n "$1" ]; then
  target="$1"
else
  target=""
  for d in $(diskutil list physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+ /{print $1}'); do
    inf="$(diskutil info "$d" 2>/dev/null)"
    printf '%s\n' "$inf" | grep -qE 'Internal:[[:space:]]+Yes' || continue
    printf '%s\n' "$inf" | grep -qE 'Removable Media:[[:space:]]+Removable' && continue
    target="${target:+$target }$d"
  done
fi
if [ "$(printf '%s' "$target" | wc -w)" -ne 1 ]; then
  say "!! Zielplatte nicht eindeutig (gefunden: ${target:-keine})."
  say "   Bitte erneut mit Plattennamen starten, z. B.:  bash \"$0\" /dev/disk0"
  diskutil list internal 2>/dev/null
  exit 1
fi
target="$(printf '%s' "$target" | tr -d ' ')"
say "Zielplatte: $target"
diskutil info "$target" 2>/dev/null | grep -E 'Device / Media Name|Disk Size' | sed 's/^/   /'

# 3. Sicherheits-Countdown (kein Tippen noetig; Abbruch mit Strg-C).
say ""
say ">> $target wird KOMPLETT GELOESCHT und macOS neu installiert."
say ">> Abbruch mit Strg-C. Start in:"
i=10; while [ "$i" -gt 0 ]; do printf ' %s' "$i"; sleep 1; i=$((i-1)); done; say ""

# 4. Formatieren (APFS / GUID).
say "- Platte wird als APFS formatiert..."
diskutil eraseDisk APFS "Macintosh HD" GPT "$target" || { say "Formatieren fehlgeschlagen."; exit 1; }
tvol="/Volumes/Macintosh HD"

# 5. Installer-App aus dem pkg bauen (auf der frischen Platte - dort ist Platz).
say "- Installer wird entpackt (gross, bitte warten)..."
build="$tvol/.macOS-Installer"; mkdir -p "$build"
caffeinate -d -i pkgutil --expand-full "$pkg" "$build/pkg" || { say "Entpacken fehlgeschlagen (pkgutil)."; exit 1; }
app="$(find "$build/pkg" -maxdepth 4 -name 'Install macOS*.app' -type d 2>/dev/null | head -n1)"
[ -d "$app" ] || { say "Installer-App im entpackten Paket nicht gefunden."; exit 1; }
say "- App: $app"

# 6. Installation starten (nicht-interaktiv). Fallback: Installer-App direkt starten.
say ""
say "*** WICHTIG FUER GLEICH:"
say "*** - Stick die GANZE Installation ueber eingesteckt lassen."
say "*** - Erscheint nach einem Neustart das Boot-Menue: den NEUEN Eintrag"
say "***   'macOS Installer' waehlen (NICHT 'macOS Base System'), spaeter"
say "***   'Macintosh HD' - bis der Willkommensassistent kommt."
say "*** - Nach dem ersten Anmelden: auf dem Stick start-me.command doppelklicken"
say "***   (kopiert OpenCore auf die Platte -> bootet danach OHNE Stick, macht Fixes)."
say ""
say "- Installation wird gestartet..."
soi="$app/Contents/Resources/startosinstall"
out="$(caffeinate -d -i "$soi" --volume "$tvol" --nointeraction --agreetolicense 2>&1)"; say "$out"
if printf '%s\n' "$out" | grep -qi 'not currently supported in the Recovery'; then
  say "- startosinstall in der Recovery nicht unterstuetzt -> Installer-App wird direkt gestartet..."
  caffeinate -d -i "$app/Contents/MacOS/InstallAssistant_springboard" &
  say "!! Dieses Terminal-Fenster OFFEN lassen (Schliessen bricht die Installation ab)."
  wait
fi

# 7. startosinstall loest den Neustart in der Recovery oft NICHT selbst aus -> selbst neu starten.
say ""
say "== Vorbereitung abgeschlossen. NEUSTART in 10 Sekunden."
say "   Danach im Boot-Menue:  'macOS Installer'  waehlen (NICHT 'Base System')."
sync
i=10; while [ $i -gt 0 ]; do printf '\r   Neustart in %2d s ... ' "$i"; sleep 1; i=$((i-1)); done; echo
reboot 2>/dev/null || shutdown -r now 2>/dev/null || say "!! Bitte von Hand neu starten (Apfel-Menue > Neustart)."

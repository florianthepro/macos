#!/bin/bash
# offline-install.command - macOS offline installieren: EIN Kommando, keine Rueckfragen.
# Formatiert die interne Platte automatisch, kopiert OpenCore (mit gueltiger Seriennummer)
# auf ihre EFI-Partition -> bootet danach OHNE Stick und ist iMessage-vorbereitet, und
# installiert macOS offline. Optionales Argument: Zielplatte (/dev/diskN); sonst Auto-Erkennung.
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

# 2. OpenCore-EFI-Quelle auf DEMSELBEN USB-Stick finden (per Dateisystem, nicht per Name).
efisrc=""
selfdev="/dev/$(stat -f '%Sd' "$here" 2>/dev/null)"
whole="$(diskutil info "$selfdev" 2>/dev/null | awk -F': *' '/Part of Whole/{print $2; exit}')"
if [ -n "$whole" ]; then
  for id in $(diskutil list "/dev/$whole" 2>/dev/null | awk '/^ +[0-9]+:/{print $NF}'); do
    inf="$(diskutil info "/dev/$id" 2>/dev/null)"
    printf '%s\n' "$inf" | grep -qiE 'File System Personality: *(MS-DOS|FAT)' || continue
    diskutil mount "/dev/$id" >/dev/null 2>&1 \
      || { mkdir -p "/Volumes/$id" && /sbin/mount_msdos "/dev/$id" "/Volumes/$id" >/dev/null 2>&1; }
    mp="$(diskutil info "/dev/$id" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
    [ -n "$mp" ] && [ -d "$mp/EFI/OC" ] && { efisrc="$mp/EFI"; break; }
  done
fi
if [ -n "$efisrc" ]; then say "OpenCore-Quelle: $efisrc"
else say "!! OpenCore-EFI auf dem Stick nicht gefunden - EFI wird NICHT kopiert (dann Stick eingesteckt lassen)."; fi

# 3. Zielplatte: Argument, sonst genau eine interne, nicht-entfernbare physische Platte.
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

# 4. Sicherheits-Countdown (kein Tippen noetig; Abbruch mit Strg-C).
say ""
say ">> $target wird KOMPLETT GELOESCHT und macOS neu installiert."
say ">> Abbruch mit Strg-C. Start in:"
i=10; while [ "$i" -gt 0 ]; do printf ' %s' "$i"; sleep 1; i=$((i-1)); done; say ""

# 5. Formatieren (APFS / GUID -> legt zugleich die interne EFI-Partition an).
say "- Platte wird als APFS formatiert..."
diskutil eraseDisk APFS "Macintosh HD" GPT "$target" || { say "Formatieren fehlgeschlagen."; exit 1; }
tvol="/Volumes/Macintosh HD"

# 6. OpenCore auf die interne EFI-Partition kopieren: bootet ohne Stick, traegt die gueltige
#    Seriennummer fuer iMessage, und die Install-Reboots laufen von selbst weiter (kein Haenger).
if [ -n "$efisrc" ]; then
  esp="$(diskutil list "$target" 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
  if [ -n "$esp" ]; then
    diskutil mount "/dev/$esp" >/dev/null 2>&1
    espmp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
    if [ -n "$espmp" ]; then
      if ditto "$efisrc" "$espmp/EFI"; then say "- OpenCore auf interne EFI kopiert ($espmp/EFI)."
      else say "!! EFI-Kopie fehlgeschlagen - Stick beim Installieren eingesteckt lassen."; fi
    fi
  fi
fi

# 7. Installer-App aus dem pkg bauen (auf der frischen Platte - dort ist Platz).
say "- Installer wird entpackt (gross, bitte warten)..."
build="$tvol/.macOS-Installer"; mkdir -p "$build"
caffeinate -d -i pkgutil --expand-full "$pkg" "$build/pkg" || { say "Entpacken fehlgeschlagen (pkgutil)."; exit 1; }
app="$(find "$build/pkg" -maxdepth 4 -name 'Install macOS*.app' -type d 2>/dev/null | head -n1)"
[ -d "$app" ] || { say "Installer-App im entpackten Paket nicht gefunden."; exit 1; }
say "- App: $app"

# 8. Installation starten (nicht-interaktiv). Fallback: Installer-App direkt starten.
say "- Installation wird gestartet..."
soi="$app/Contents/Resources/startosinstall"
out="$(caffeinate -d -i "$soi" --volume "$tvol" --nointeraction --agreetolicense 2>&1)"; say "$out"
if printf '%s\n' "$out" | grep -qi 'not currently supported in the Recovery'; then
  say "- startosinstall in der Recovery nicht unterstuetzt -> Installer-App wird direkt gestartet..."
  caffeinate -d -i "$app/Contents/MacOS/InstallAssistant_springboard" &
  say "!! Dieses Terminal-Fenster OFFEN lassen (Schliessen bricht die Installation ab)."
  wait
fi

say ""
say "== Fertig. Der Rechner startet neu und installiert weiter."
say "   Falls das OpenCore-Menue erscheint: 'macOS Installer' waehlen, bis der"
say "   Willkommensbildschirm kommt. Danach bootet die Platte OHNE Stick."

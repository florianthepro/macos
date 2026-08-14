#!/bin/bash
# battery.command - Batterieanzeige unter macOS aktivieren (Laptop). macOS kennt den Akku erst,
# wenn SMCBatteryManager (VirtualSMC-Plugin) laedt; ECEnabler laesst dazu die Lenovo-EC-Werte
# korrekt lesen (noetig fuer ThinkPads, sonst 0%/keine Anzeige). Sicher: Backup + plutil-Pruefung
# mit automatischem Rueckbau.  sudo bash battery.command
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy

esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; KEXTS="$mp/EFI/OC/Kexts"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }
say "EFI: $mp"
cp "$CFG" "$CFG.batbak"

tmp="$(mktemp -d)"
get(){ curl -fsSL "$1" -o "$tmp/z.zip" 2>/dev/null && unzip -oq "$tmp/z.zip" -d "$tmp/x" && return 0; return 1; }
place(){ local k; k="$(find "$tmp/x" -maxdepth 4 -type d -name "$1" 2>/dev/null | head -n1)"; [ -n "$k" ] && { rm -rf "$KEXTS/$1"; cp -R "$k" "$KEXTS/$1"; }; }
say "- Kexte laden ..."
get "https://github.com/acidanthera/VirtualSMC/releases/download/1.3.7/VirtualSMC-1.3.7-RELEASE.zip" && place SMCBatteryManager.kext
rm -rf "$tmp/x"
get "https://github.com/1Revenger1/ECEnabler/releases/download/1.0.5/ECEnabler-1.0.5-RELEASE.zip"    && place ECEnabler.kext

add(){ local b="$1" e="$2" i
  [ -d "$KEXTS/$b" ] || { say "  (fehlt, uebersprungen: $b)"; return 0; }
  $PB -c "Print :Kernel:Add" "$CFG" 2>/dev/null | grep -q "BundlePath = $b\$" && { say "  schon drin: $b"; return 0; }
  /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
  i="$(/usr/bin/plutil -extract Kernel.Add raw -o - "$CFG" 2>/dev/null)"; case "$i" in ''|*[!0-9]*) say "  Index-Fehler $b"; return 1;; esac
  $PB -c "Add :Kernel:Add:$i dict" -c "Add :Kernel:Add:$i:Arch string x86_64" -c "Add :Kernel:Add:$i:BundlePath string $b" \
      -c "Add :Kernel:Add:$i:Comment string $b" -c "Add :Kernel:Add:$i:Enabled bool true" -c "Add :Kernel:Add:$i:ExecutablePath string $e" \
      -c "Add :Kernel:Add:$i:MaxKernel string " -c "Add :Kernel:Add:$i:MinKernel string " \
      -c "Add :Kernel:Add:$i:PlistPath string Contents/Info.plist" "$CFG" && say "  + $b"
}
add SMCBatteryManager.kext "Contents/MacOS/SMCBatteryManager"
add ECEnabler.kext "Contents/MacOS/ECEnabler"

/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
  say ""
  say "== OK. Bitte NEU STARTEN."
  say "   Danach: Systemeinstellungen > Kontrollzentrum > Batterie ->"
  say "   'In Menueleiste anzeigen' + 'Prozent anzeigen'. (Uhr: ebenda unter 'Uhr'.)"
  say "   Backup: $CFG.batbak"
else
  say "!! config.plist ungueltig -> Backup wird zurueckgespielt."; cp "$CFG.batbak" "$CFG"; exit 1
fi

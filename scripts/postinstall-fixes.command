#!/bin/bash
# postinstall-fixes.command - Ton (AppleALC) + Bluetooth-Kexts in die INTERNE EFI eintragen.
# Sicher: Backup + Validierung; bei Fehler automatischer Rueckbau. Das Backup bleibt als
# config.plist.bak liegen (bei Boot-Problem: USB-Stick booten und config.plist.bak zurueck-
# kopieren). Mit sudo ausfuehren.
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }

# 1. Interne EFI finden + mounten
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI-Partition nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; KEXTS="$mp/EFI/OC/Kexts"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden ($CFG)."; exit 1; }
say "EFI: $mp"
cp "$CFG" "$CFG.bak" || { say "Backup fehlgeschlagen"; exit 1; }

# 2. Kexts laden
tmp="$(mktemp -d)"
get(){ curl -fsSL "$1" -o "$tmp/z.zip" && unzip -oq "$tmp/z.zip" -d "$tmp/x" && return 0; say "  Download fehlgeschlagen: $1"; return 1; }
place(){ local k; k="$(find "$tmp/x" -maxdepth 4 -type d -name "$1" 2>/dev/null | head -n1)"; [ -n "$k" ] && { rm -rf "$KEXTS/$1"; cp -R "$k" "$KEXTS/$1"; }; }
say "- Kexts werden geladen ..."
get "https://github.com/acidanthera/AppleALC/releases/download/1.9.2/AppleALC-1.9.2-RELEASE.zip"                        && place AppleALC.kext
get "https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip"                                && place Lilu.kext
get "https://github.com/OpenIntelWireless/IntelBluetoothFirmware/releases/download/v2.4.0/IntelBluetooth-v2.4.0.zip"    && { place IntelBluetoothFirmware.kext; place IntelBTPatcher.kext; }
get "https://github.com/acidanthera/BrcmPatchRAM/releases/download/2.7.2/BrcmPatchRAM-2.7.2-RELEASE.zip"                && place BlueToolFixup.kext

# 3. In config.plist eintragen (Lilu zuerst; Dublettenschutz; Datei muss existieren)
add(){ # BundlePath ExecutablePath
  local b="$1" e="$2"
  [ -d "$KEXTS/$b" ] || { say "  (fehlt, uebersprungen: $b)"; return 0; }
  /usr/libexec/PlistBuddy -c "Print :Kernel:Add" "$CFG" 2>/dev/null | grep -q "BundlePath = $b\$" && { say "  schon drin: $b"; return 0; }
  local i; i="$(/usr/bin/plutil -extract Kernel.Add raw -o - "$CFG" 2>/dev/null)"
  case "$i" in ''|*[!0-9]*) say "  Index-Fehler bei $b"; return 1;; esac
  /usr/libexec/PlistBuddy \
    -c "Add :Kernel:Add:$i dict" \
    -c "Add :Kernel:Add:$i:Arch string x86_64" \
    -c "Add :Kernel:Add:$i:BundlePath string $b" \
    -c "Add :Kernel:Add:$i:Comment string $b" \
    -c "Add :Kernel:Add:$i:Enabled bool true" \
    -c "Add :Kernel:Add:$i:ExecutablePath string $e" \
    -c "Add :Kernel:Add:$i:MaxKernel string " \
    -c "Add :Kernel:Add:$i:MinKernel string " \
    -c "Add :Kernel:Add:$i:PlistPath string Contents/Info.plist" \
    "$CFG" && say "  + $b"
}
add Lilu.kext "Contents/MacOS/Lilu"
add AppleALC.kext "Contents/MacOS/AppleALC"
add IntelBluetoothFirmware.kext "Contents/MacOS/IntelBluetoothFirmware"
add IntelBTPatcher.kext "Contents/MacOS/IntelBTPatcher"
add BlueToolFixup.kext "Contents/MacOS/BlueToolFixup"

# 4. Audio-Boot-Arg alcid=11 ergaenzen (falls noch nicht vorhanden)
BA="7C436110-AB2A-4BBB-A880-FE41995C9F82"
cur="$(/usr/libexec/PlistBuddy -c "Print :NVRAM:Add:$BA:boot-args" "$CFG" 2>/dev/null)"
case "$cur" in
  *alcid=*) : ;;
  *) newv="alcid=11${cur:+ $cur}"
     /usr/libexec/PlistBuddy -c "Set :NVRAM:Add:$BA:boot-args $newv" "$CFG" 2>/dev/null \
       || /usr/libexec/PlistBuddy -c "Add :NVRAM:Add:$BA:boot-args string alcid=11" "$CFG" ;;
esac

# 5. Validieren -> bei Fehler Backup zurueck
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
  say ""
  say "== OK. Bitte NEU STARTEN."
  say "   - Ton: sollte gehen. Kein Ton? alcid-Wert testen: 11, 13, 21, 22, 27, 28, 29"
  say "     (in boot-args aendern) - der Codec entscheidet."
  say "   - Bluetooth: Kexts sind drin, BT erscheint aber erst nach USB-Port-Mapping"
  say "     (USBToolBox). Backup: $CFG.bak"
else
  say "!! config.plist wurde ungueltig -> Backup wird zurueckgespielt (keine Aenderung)."
  cp "$CFG.bak" "$CFG"
  exit 1
fi

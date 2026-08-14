#!/bin/bash
# bluetooth.command - Intel-Bluetooth unter macOS aktivieren. Traegt die noetigen Kexte + den
# boot-arg -btlfxallowanyaddr ein. Ist das BT-USB-Modul (VID 0x8087) danach nicht sichtbar, ist
# sein interner Port nicht gemappt -> usb-fix.command uebernimmt die USB-Portmap. Sicher: Backup +
# plutil-Pruefung mit automatischem Rueckbau.  sudo bash bluetooth.command
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy
BASE="https://raw.githubusercontent.com/florianthepro/macos/main"

say "Voraussetzung: BIOS (F1) Security > I/O Port Access > Bluetooth/Wireless = On, Fn+F8 (Funk an)."
say ""

esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; KEXTS="$mp/EFI/OC/Kexts"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }
[ -d "$KEXTS" ] || mkdir -p "$KEXTS"
say "EFI: $mp"
cp "$CFG" "$CFG.btbak"

# --- 1) BT-Kexte sicherstellen ---
tmp="$(mktemp -d)"
get(){ curl -fsSL "$1" -o "$tmp/z.zip" 2>/dev/null && unzip -oq "$tmp/z.zip" -d "$tmp/x" && return 0; return 1; }
place(){ local k; k="$(find "$tmp/x" -maxdepth 4 -type d -name "$1" 2>/dev/null | head -n1)"; [ -n "$k" ] && { rm -rf "$KEXTS/$1"; cp -R "$k" "$KEXTS/$1"; }; }
say "- BT-Kexte laden ..."
get "https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip"                             && place Lilu.kext
get "https://github.com/OpenIntelWireless/IntelBluetoothFirmware/releases/download/v2.4.0/IntelBluetooth-v2.4.0.zip"  && { place IntelBluetoothFirmware.kext; place IntelBTPatcher.kext; }
get "https://github.com/acidanthera/BrcmPatchRAM/releases/download/2.7.2/BrcmPatchRAM-2.7.2-RELEASE.zip"              && place BlueToolFixup.kext
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
add Lilu.kext "Contents/MacOS/Lilu"
add IntelBluetoothFirmware.kext "Contents/MacOS/IntelBluetoothFirmware"
add IntelBTPatcher.kext "Contents/MacOS/IntelBTPatcher"
add BlueToolFixup.kext "Contents/MacOS/BlueToolFixup"

# --- 2) boot-arg -btlfxallowanyaddr ---
BA=7C436110-AB2A-4BBB-A880-FE41995C9F82
cur="$($PB -c "Print :NVRAM:Add:$BA:boot-args" "$CFG" 2>/dev/null)"
case "$cur" in *btlfxallowanyaddr*) : ;; *) newv="-btlfxallowanyaddr${cur:+ $cur}"
  $PB -c "Set :NVRAM:Add:$BA:boot-args $newv" "$CFG" 2>/dev/null || $PB -c "Add :NVRAM:Add:$BA:boot-args string -btlfxallowanyaddr" "$CFG" 2>/dev/null
  say "- boot-arg -btlfxallowanyaddr ergaenzt." ;; esac

/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
/usr/bin/plutil -lint "$CFG" >/dev/null 2>&1 || { say "!! config ungueltig -> Rueckbau."; cp "$CFG.btbak" "$CFG"; exit 1; }

# --- 3) BT-USB-Geraet vorhanden? ---
USB="$(system_profiler SPUSBDataType 2>/dev/null)"
if printf '%s' "$USB" | grep -qiE '0x8087|Bluetooth USB Host'; then
  say ""
  say ">> BT-Modul ist am USB sichtbar + Kexte/boot-arg gesetzt. NEU STARTEN -> Bluetooth sollte gehen."
  exit 0
fi

say ""
say "BT-Modul ist NICHT am USB - der interne Port ist nicht gemappt."
say "-> usb-fix.command baut jetzt die USB-Portmap und startet neu (danach ist BT da)."
say ""
if curl -fsSL "$BASE/scripts/usb-fix.command" -o /tmp/usb-fix.command; then
  exec bash /tmp/usb-fix.command
else
  say "!! Download von usb-fix.command fehlgeschlagen. Manuell ausfuehren:"
  say "   curl -fsSL \"$BASE/scripts/usb-fix.command\" -o /tmp/usb-fix.command && sudo bash /tmp/usb-fix.command"
  exit 1
fi

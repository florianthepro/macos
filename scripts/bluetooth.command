#!/bin/bash
# bluetooth.command - Intel-Bluetooth unter macOS aktivieren. Generisch fuer ThinkPad-/Lenovo-
# Modelle mit Intel-WLAN/BT (8265/9260/AX200/AX201). Traegt die noetigen Kexte + den boot-arg
# -btlfxallowanyaddr ein und macht - falls das BT-USB-Geraet versteckt ist - die internen Ports
# sichtbar (RHUB-Reset). Sicher: Backup + plutil-Pruefung, bei Fehler automatischer Rueckbau.
#   sudo bash bluetooth.command
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy

say "Voraussetzung: im BIOS (F1) Security > I/O Port Access > Bluetooth/Wireless = On, Fn+F8 (Funk an)."
say ""

# --- interne EFI mounten ---------------------------------------------------------
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; KEXTS="$mp/EFI/OC/Kexts"; ACPIDIR="$mp/EFI/OC/ACPI"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }
[ -d "$KEXTS" ] || mkdir -p "$KEXTS"; [ -d "$ACPIDIR" ] || mkdir -p "$ACPIDIR"
say "EFI: $mp"
cp "$CFG" "$CFG.btbak"

# --- 1) BT-Kexte sicherstellen ---------------------------------------------------
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

# --- 2) boot-arg -btlfxallowanyaddr ---------------------------------------------
BA=7C436110-AB2A-4BBB-A880-FE41995C9F82
cur="$($PB -c "Print :NVRAM:Add:$BA:boot-args" "$CFG" 2>/dev/null)"
case "$cur" in *btlfxallowanyaddr*) : ;; *) newv="-btlfxallowanyaddr${cur:+ $cur}"
  $PB -c "Set :NVRAM:Add:$BA:boot-args $newv" "$CFG" 2>/dev/null || $PB -c "Add :NVRAM:Add:$BA:boot-args string -btlfxallowanyaddr" "$CFG" 2>/dev/null
  say "- boot-arg -btlfxallowanyaddr ergaenzt." ;; esac

# --- Kext/boot-arg-Aenderungen validieren ---------------------------------------
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
/usr/bin/plutil -lint "$CFG" >/dev/null 2>&1 || { say "!! config ungueltig -> Rueckbau."; cp "$CFG.btbak" "$CFG"; exit 1; }

# --- 3) Ist das BT-USB-Geraet ueberhaupt da? ------------------------------------
USB="$(system_profiler SPUSBDataType 2>/dev/null)"
if printf '%s' "$USB" | grep -qiE '0x8087|Bluetooth USB Host'; then
  say ""
  say ">> BT-Modul ist am USB sichtbar + Kexte/boot-arg gesetzt. NEU STARTEN -> Bluetooth sollte gehen."
  say "   Danach kein BT? SPBluetoothDataType pruefen und melden."
  exit 0
fi

say ""
say "BT-Modul ist NICHT am USB - interne Ports muessen sichtbar gemacht werden (Reveal)."

# --- generischer Reveal (identisch zu camera.command) ---------------------------
ensure_reveal(){
  local CFG="$1" ACPIDIR="$2"
  if $PB -c "Print :ACPI:Patch" "$CFG" 2>/dev/null | grep -q "RHUB reveal"; then echo already; return 0; fi
  local U H IASL paths dsl aml STA XSTA i p bp
  U="${SUDO_USER:-$USER}"; H="$(eval echo ~"$U")"; IASL="$H/iasl"
  [ -x "$IASL" ] || { curl -fsSL "https://raw.githubusercontent.com/acidanthera/MaciASL/master/Dist/iasl-stable" -o "$IASL" 2>/dev/null && chmod +x "$IASL"; }
  [ -x "$IASL" ] || { echo guide; return 0; }
  [ -d "$H/USBMap" ] || sudo -u "$U" git clone https://github.com/corpnewt/USBMap "$H/USBMap" >/dev/null 2>&1
  paths="$( (cd "$H/USBMap" 2>/dev/null && printf 'q\n' | sudo -u "$U" python3 USBMap.py 2>/dev/null) | grep -oE 'RHUB @ [^ ]+' | awk '{print $3}' | sort -u )"
  [ -n "$paths" ] || { echo guide; return 0; }
  dsl=/tmp/SSDT-USB-Reset.dsl; aml=/tmp/SSDT-USB-Reset.aml
  { echo 'DefinitionBlock ("", "SSDT", 2, "OCLT", "RHBRST", 0x00001000)'; echo '{'
    for p in $paths; do
      echo "    External ($p, DeviceObj)"
      echo "    Scope ($p) { Method (_STA, 0, NotSerialized) { If (_OSI (\"Darwin\")) { Return (Zero) } Else { Return (0x0F) } } }"
    done; echo '}'; } > "$dsl"
  rm -f "$aml"; "$IASL" "$dsl" >/dev/null 2>&1
  [ -f "$aml" ] || { echo guide; return 0; }
  cp "$CFG" "$CFG.revealbak"
  cp "$aml" "$ACPIDIR/SSDT-USB-Reset.aml"
  if ! $PB -c "Print :ACPI:Add" "$CFG" 2>/dev/null | grep -q "Path = SSDT-USB-Reset.aml"; then
    /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
    i="$(/usr/bin/plutil -extract ACPI.Add raw -o - "$CFG" 2>/dev/null)"; case "$i" in ''|*[!0-9]*) i="";; esac
    [ -n "$i" ] && $PB -c "Add :ACPI:Add:$i dict" -c "Add :ACPI:Add:$i:Comment string SSDT-USB-Reset" \
      -c "Add :ACPI:Add:$i:Enabled bool true" -c "Add :ACPI:Add:$i:Path string SSDT-USB-Reset.aml" "$CFG"
  fi
  STA="$(printf '_STA'|base64)"; XSTA="$(printf 'XSTA'|base64)"
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><array>'
    for p in $paths; do case "$p" in \\*) bp="$p";; *) bp="\\$p";; esac
      echo "<dict><key>Base</key><string>$bp</string><key>BaseSkip</key><integer>0</integer><key>Comment</key><string>RHUB reveal: _STA to XSTA</string><key>Count</key><integer>1</integer><key>Enabled</key><true/><key>Find</key><data>$STA</data><key>Limit</key><integer>0</integer><key>Mask</key><data></data><key>OemTableId</key><data></data><key>Replace</key><data>$XSTA</data><key>ReplaceMask</key><data></data><key>Skip</key><integer>0</integer><key>TableLength</key><integer>0</integer><key>TableSignature</key><data></data></dict>"
    done; echo '</array></plist>'; } > /tmp/reveal_patches.plist
  $PB -c "Print :ACPI:Patch" "$CFG" >/dev/null 2>&1 || $PB -c "Add :ACPI:Patch array" "$CFG" 2>/dev/null
  $PB -c "Merge /tmp/reveal_patches.plist :ACPI:Patch" "$CFG" 2>/dev/null
  /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
  if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then echo applied; else cp "$CFG.revealbak" "$CFG"; echo failed; fi
}

state="$(ensure_reveal "$CFG" "$ACPIDIR")"
say ""
case "$state" in
  applied) say ">> Reveal erzeugt und eingetragen. NEU STARTEN, dann bluetooth.command nochmal." ;;
  already) say ">> Reveal ist bereits aktiv, BT-Modul aber (noch) nicht sichtbar."
           say "   1) Erst NEU STARTEN und pruefen."
           say "   2) Bleibt es weg: Controller hat >15 Ports -> USB-Mapping (USBMap -> P,"
           say "      BT-Port als Typ 255 behalten, dann usb-map-install.command)." ;;
  failed)  say "!! Reveal-Automatik fehlgeschlagen - config.plist zurueckgesetzt. Manuell: USBMap -> H, ssdt-install.command." ;;
  guide)   say ">> RHUB-Pfade nicht automatisch ermittelbar. Manuell: cd ~/USBMap && ./USBMap.command -> H, dann ssdt-install.command." ;;
esac

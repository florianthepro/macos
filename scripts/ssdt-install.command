#!/bin/bash
# ssdt-install.command - Installiert EINE .aml (z.B. SSDT-RHUB-Reset.aml) sicher in die interne
# EFI: kopiert nach EFI/OC/ACPI und traegt sie in config.plist ACPI:Add ein. Backup +
# plutil-Pruefung, bei Fehler automatischer Rueckbau. Dublettenschutz.
#   sudo bash ssdt-install.command /pfad/zur/SSDT-RHUB-Reset.aml
# Ohne Pfad wird in ~/USBMap/Results, ~/Downloads, ~/Desktop nach *.aml gesucht.
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\" /pfad/zur/SSDT.aml"; exit 1; }

# 1) .aml finden
AML="$1"
if [ -z "$AML" ]; then
  for d in "$HOME/USBMap/Results" "$HOME/Downloads" "$HOME/Desktop" "$HOME"; do
    c="$(find "$d" -maxdepth 2 -type f -iname 'SSDT-RHUB*.aml' 2>/dev/null | head -n1)"
    [ -n "$c" ] && { AML="$c"; break; }
  done
fi
[ -n "$AML" ] && [ -f "$AML" ] || { say "!! Keine .aml gefunden. Pfad angeben:  sudo bash \"$0\" ~/USBMap/Results/SSDT-RHUB-Reset.aml"; exit 1; }
case "$AML" in *.aml) : ;; *) say "!! $AML ist keine .aml (kompilierte ACPI-Datei). .dsl zuerst mit iasl kompilieren."; exit 1;; esac
base="$(basename "$AML")"
say "SSDT: $AML"

# 2) Interne EFI mounten + config.plist
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI-Partition nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; ACPIDIR="$mp/EFI/OC/ACPI"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden ($CFG)."; exit 1; }
[ -d "$ACPIDIR" ] || mkdir -p "$ACPIDIR"
say "EFI: $mp"
cp "$CFG" "$CFG.ssdtbak" || { say "Backup fehlgeschlagen"; exit 1; }
PB=/usr/libexec/PlistBuddy

# 3) .aml kopieren
cp "$AML" "$ACPIDIR/$base" || { say "!! Kopieren fehlgeschlagen."; exit 1; }
say "- $base nach EFI/OC/ACPI kopiert."

# 4) In ACPI:Add eintragen (Dublettenschutz)
if $PB -c "Print :ACPI:Add" "$CFG" 2>/dev/null | grep -q "Path = $base\$"; then
  say "- $base war schon in ACPI:Add (ok)."
else
  /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
  i="$(/usr/bin/plutil -extract ACPI.Add raw -o - "$CFG" 2>/dev/null)"
  case "$i" in ''|*[!0-9]*) say "!! Index konnte nicht bestimmt werden."; cp "$CFG.ssdtbak" "$CFG"; exit 1;; esac
  $PB \
    -c "Add :ACPI:Add:$i dict" \
    -c "Add :ACPI:Add:$i:Comment string $base" \
    -c "Add :ACPI:Add:$i:Enabled bool true" \
    -c "Add :ACPI:Add:$i:Path string $base" \
    "$CFG" && say "- $base in ACPI:Add eingetragen (Index $i)."
fi

# 5) Validieren -> bei Fehler Backup zurueck
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
  say ""
  say "== OK. Bitte NEU STARTEN."
  say "   Danach USBMap erneut -> D (Discover): Kamera (VID 0x04f2/0x5986/0x1bcf) und"
  say "   Bluetooth (VID 0x8087) sollten nun als HS-Ports auftauchen."
  say "   Rettung bei Boot-Problem: vom USB-Stick booten, dann"
  say "   cp \"$CFG.ssdtbak\" \"$CFG\"  und $ACPIDIR/$base loeschen."
  say "   Backup: $CFG.ssdtbak"
else
  say "!! config.plist wurde ungueltig -> Backup wird zurueckgespielt (keine Aenderung)."
  cp "$CFG.ssdtbak" "$CFG"; rm -f "$ACPIDIR/$base"; exit 1
fi

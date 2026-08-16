#!/usr/bin/env bash
# build-vce.sh - baut den VCE-EFI-Ordner (Stufe 1: Universal-Boot + Netz-Installer).
# Ergebnis: <out>/EFI/BOOT/BOOTX64.EFI (iPXE) + autoexec.ipxe, die das Bootmenue
# von DEINEM Server laedt. Den Ordner auf einen FAT32-Stick legen -> UEFI-bootbar.
#
#   ./build-vce.sh --server http://mein-server.example [--out ./vce-efi]
#
# Optional: --oc-tools /pfad/zu/EFI/OC  legt ipxe.efi zusaetzlich als OpenCore-Tool
# ab (Eintrag in Misc->Tools der config.plist muss manuell ergaenzt werden).
set -euo pipefail
say(){ printf '%s\n' "$*"; }

SERVER=""; OUT="./vce-efi"; OCTOOLS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="${2:?}"; shift 2 ;;
    --out)    OUT="${2:?}"; shift 2 ;;
    --oc-tools) OCTOOLS="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) say "Unbekannte Option: $1"; exit 1 ;;
  esac
done
[ -n "$SERVER" ] || { say "!! --server fehlt.  Beispiel: ./build-vce.sh --server http://mein-server.example"; exit 1; }
SERVER="${SERVER%/}"

IPXE_URL="https://boot.ipxe.org/x86_64-efi/ipxe.efi"

say "== VCE bauen =="
say "Server: $SERVER"
mkdir -p "$OUT/EFI/BOOT"

say "- iPXE wird geladen ($IPXE_URL)"
curl -fsSL "$IPXE_URL" -o "$OUT/EFI/BOOT/BOOTX64.EFI"
size=$(wc -c < "$OUT/EFI/BOOT/BOOTX64.EFI")
[ "$size" -gt 100000 ] || { say "!! ipxe.efi unerwartet klein ($size B) - Download defekt?"; exit 1; }

# autoexec.ipxe liegt neben der Binary; iPXE (EFI) fuehrt sie automatisch aus.
cat > "$OUT/EFI/BOOT/autoexec.ipxe" <<EOF
#!ipxe
echo === VCE - Virtual Compatible EFI ===
echo Netzwerk wird konfiguriert (DHCP) ...
dhcp || goto nonet
echo Lade Menue von $SERVER ...
chain $SERVER/vce/menu.ipxe || goto nomenu
exit

:nonet
echo !! Kein Netzwerk (Kabel einstecken). Weiter in die iPXE-Shell.
shell

:nomenu
echo !! Menue nicht erreichbar: $SERVER/vce/menu.ipxe
echo    Server pruefen (vce/server/README.md). Weiter in die iPXE-Shell.
shell
EOF

if [ -n "$OCTOOLS" ]; then
  mkdir -p "$OCTOOLS/Tools"
  cp "$OUT/EFI/BOOT/BOOTX64.EFI" "$OCTOOLS/Tools/ipxe.efi"
  say "- ipxe.efi als OpenCore-Tool abgelegt: $OCTOOLS/Tools/ipxe.efi"
  say "  (In config.plist unter Misc->Tools eintragen: Path=ipxe.efi, Name=VCE Netz-Installation)"
fi

say ""
say "== FERTIG: $OUT"
say "   Inhalt auf einen FAT32-Stick kopieren (Ordner EFI in die Stick-Wurzel)."
say "   Beim Booten laedt VCE das Menue von: $SERVER/vce/menu.ipxe"
say "   Serverseite einrichten: vce/server/README.md"

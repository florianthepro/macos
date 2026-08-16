#!/usr/bin/env bash
# add-to-opencore.sh - haengt VCE (iPXE) als Tool in den OpenCore-Picker eines Sticks/Systems.
# Danach ist "VCE Netz-Installation" ein Menuepunkt im normalen Boot-Menue ("Taste beim Booten").
#
#   ./add-to-opencore.sh /pfad/zum/EFI            # EFI-Ordner mit OC/config.plist darin
#   ./add-to-opencore.sh /Volumes/EFI/EFI         # Beispiel macOS (EFI-Partition gemountet)
#
# Laedt iPXE bei Bedarf selbst. Sicher: Backup der config.plist + Validierung (python3/plistlib),
# bei Fehler automatischer Rueckbau. Laeuft unter macOS und Linux (braucht curl + python3).
set -euo pipefail
say(){ printf '%s\n' "$*"; }

EFI="${1:-}"
[ -n "$EFI" ] && [ -d "$EFI/OC" ] || { say "Aufruf: $0 /pfad/zum/EFI   (Ordner, der OC/ enthaelt)"; exit 1; }
CFG="$EFI/OC/config.plist"
[ -f "$CFG" ] || { say "!! $CFG nicht gefunden."; exit 1; }
command -v python3 >/dev/null || { say "!! python3 fehlt."; exit 1; }

TOOLS="$EFI/OC/Tools"; mkdir -p "$TOOLS"
if [ ! -f "$TOOLS/ipxe.efi" ]; then
  say "- iPXE wird geladen"
  curl -fsSL "https://boot.ipxe.org/x86_64-efi/ipxe.efi" -o "$TOOLS/ipxe.efi"
fi
[ "$(wc -c < "$TOOLS/ipxe.efi")" -gt 100000 ] || { say "!! ipxe.efi defekt."; exit 1; }

cp "$CFG" "$CFG.vcebak"
if python3 - "$CFG" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f:
    cfg = plistlib.load(f)
tools = cfg.setdefault("Misc", {}).setdefault("Tools", [])
if any(isinstance(t, dict) and t.get("Path") == "ipxe.efi" for t in tools):
    print("schon eingetragen")
else:
    tools.append({
        "Arguments": "", "Auxiliary": False, "Comment": "VCE - Netz-Installation (iPXE)",
        "Enabled": True, "Flavour": "Auto", "FullNvramAccess": False,
        "Name": "VCE Netz-Installation", "Path": "ipxe.efi",
        "RealPath": False, "TextMode": False,
    })
    print("eingetragen")
with open(p, "wb") as f:
    plistlib.dump(cfg, f)
with open(p, "rb") as f:
    plistlib.load(f)  # Validierung: muss sauber parsen
PY
then
  say "- VCE als OpenCore-Tool registriert (Tools/ipxe.efi)."
  say "== FERTIG. Im Boot-Menue erscheint jetzt 'VCE Netz-Installation'."
  say "   (Backup: $CFG.vcebak)"
else
  say "!! Eintrag fehlgeschlagen -> Backup wird zurueckgespielt."
  cp "$CFG.vcebak" "$CFG"; exit 1
fi

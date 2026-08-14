#!/bin/bash
# start-me.command - Der EINE Schritt nach der Installation (Doppelklick genuegt).
# 1) kopiert OpenCore auf die interne Platte -> bootet danach OHNE Stick / ohne F12
#    und schaltet den Auswahlbildschirm ab (sauberer Boot),
# 2) installiert das deutsche Windows-Tastaturlayout,
# 3) sichert Kamera + Bluetooth ab, falls das Geraet nicht schon ab Werk versorgt ist.
# Danach ggf. automatischer Neustart. Fragt selbst nach dem Passwort.
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"   # sich selbst mit Administratorrechten neu starten
BASE="https://raw.githubusercontent.com/florianthepro/macos/claude/macos-usb-installer-exe-bfvxsy"
NEEDREBOOT=0

say "=============================================================="
say " Nachlauf: OpenCore intern + Tastatur + Kamera/Bluetooth"
say "=============================================================="

# ---- 1) OpenCore auf die interne EFI (UEFI-Umzug) ----------------------------------
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
if [ -n "$esp" ]; then
  diskutil mount "/dev/$esp" >/dev/null 2>&1
  mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
  if [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ]; then
    say "- OpenCore liegt bereits auf der internen Platte."
  else
    src=""
    for v in /Volumes/*; do
      [ "$v" = "$mp" ] && continue
      [ -f "$v/EFI/OC/config.plist" ] && { src="$v/EFI"; break; }
    done
    if [ -n "$src" ] && [ -n "$mp" ] && ditto "$src" "$mp/EFI"; then
      say "- OpenCore auf die interne Platte kopiert (bootet jetzt ohne Stick)."; NEEDREBOOT=1
    else
      say "- Interne EFI nicht befuellbar (Stick nicht gefunden?) - uebersprungen."
    fi
  fi
  icfg="$mp/EFI/OC/config.plist"
  if [ -f "$icfg" ]; then
    /usr/libexec/PlistBuddy -c "Set :Misc:Boot:ShowPicker false" "$icfg" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Set :Misc:Boot:Timeout 2" "$icfg" 2>/dev/null
    /usr/bin/plutil -lint "$icfg" >/dev/null 2>&1 || say "  (Boot-Feinschliff uebersprungen)"
  fi
fi

# ---- 2) Deutsches Windows-Tastaturlayout -------------------------------------------
DEST="/Library/Keyboard Layouts"; mkdir -p "$DEST"
if curl -fsSL "$BASE/assets/keyboard/Windows-German.keylayout" -o "$DEST/Windows-German.keylayout" 2>/dev/null \
   && grep -q 'code="12" output="@"' "$DEST/Windows-German.keylayout"; then
  say "- Windows-Tastaturlayout installiert (@=AltGr+Q, <>| und ^° korrekt)."
  say "  -> EINMAL auswaehlen (das Einzige, was macOS zwingend selbst verlangt):"
  say "     Systemeinstellungen > Tastatur > Eingabequellen > '+' > Deutsch >"
  say "     'Deutsch - Windows (ThinkPad)', Apple-'Deutsch' entfernen."
else
  say "- (Tastaturlayout konnte nicht geladen werden - Internet? Spaeter erneut.)"
fi

# ---- 3) Kamera/Bluetooth absichern (falls nicht ab Werk) ---------------------------
USB="$(system_profiler SPUSBDataType 2>/dev/null)"
cam=1; bt=1
printf '%s' "$USB" | grep -qiE 'camera|bison|chicony|sunplus|azurewave|0x5986|0x04f2|0x13d3|0x2b7e|0x1bcf' || cam=0
printf '%s' "$USB" | grep -qiE '0x8087' || bt=0
if [ $cam = 1 ] && [ $bt = 1 ]; then
  say "- Kamera + Bluetooth sind aktiv (ab Werk versorgt)."
else
  say "- Kamera/Bluetooth noch nicht aktiv -> USB-Portmap wird gebaut (startet selbst neu)..."
  if curl -fsSL "$BASE/scripts/usb-fix.command" -o /tmp/usb-fix.command 2>/dev/null; then
    exec bash /tmp/usb-fix.command
  else
    say "  (usb-fix.command nicht ladbar - Internet? Spaeter erneut ausfuehren.)"
  fi
fi

# ---- Abschluss ----------------------------------------------------------------------
say ""
if [ $NEEDREBOOT = 1 ]; then
  say "== FERTIG. Neustart in 6 Sekunden - danach bootet macOS ohne Stick."
  sync; for s in 6 5 4 3 2 1; do printf '\r   %ss ' "$s"; sleep 1; done; echo; reboot
else
  say "== FERTIG. Bitte nur noch das Tastaturlayout auswaehlen (siehe oben)."
fi

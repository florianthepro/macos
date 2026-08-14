#!/bin/bash
# final-fix.command - EIN Befehl fuer alles. Ist zustandsbewusst: prueft, was schon erledigt
# ist, und macht nur das Noetige. Behandelt (1) Tastatur und (2) Kamera + Bluetooth.
# Sicher: Backup der config.plist + plutil-Pruefung, bei Fehler automatischer Rueckbau.
#   Ausfuehren:  sudo bash final-fix.command
# Danach ggf. NEU STARTEN und denselben Befehl nochmal - das Script prueft dann und macht weiter.
set -o pipefail
say(){ printf '%s\n' "$*"; }
hr(){ say "------------------------------------------------------------"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy
NEEDREBOOT=0

# ============================================================ 1) TASTATUR
hr; say "== 1) TASTATUR =="
# Zuverlaessig fuer interne + externe Windows-Tastaturen: die von macOS vertauschten Tasten
# "<>|" (HID 0x64) und "^/°" (HID 0x35) global zuruecktauschen, persistent per LaunchDaemon.
KB_MAP='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000064,"HIDKeyboardModifierMappingDst":0x700000035},{"HIDKeyboardModifierMappingSrc":0x700000035,"HIDKeyboardModifierMappingDst":0x700000064}]}'
DAEMON=/Library/LaunchDaemons/com.local.keyboard-iso-fix.plist
cat > "$DAEMON" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.local.keyboard-iso-fix</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/hidutil</string>
        <string>property</string>
        <string>--set</string>
        <string>$KB_MAP</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
chmod 644 "$DAEMON"; chown root:wheel "$DAEMON"
launchctl bootout system "$DAEMON" 2>/dev/null
launchctl bootstrap system "$DAEMON" 2>/dev/null || launchctl load "$DAEMON" 2>/dev/null
/usr/bin/hidutil property --set "$KB_MAP" >/dev/null 2>&1
say "Taste \"<>|\" macht wieder <>| und \"^/°\" wieder ^/° - sofort aktiv, bleibt nach Neustart."
say "(Gilt fuer interne/externe Windows-Tastaturen. Nutzt du mal eine echte Apple-ISO-Tastatur"
say " und die zwei Tasten sind DORT vertauscht: LaunchDaemon $DAEMON loeschen.)"

# ============================================================ 2) KAMERA + BLUETOOTH
hr; say "== 2) KAMERA + BLUETOOTH =="
USB="$(system_profiler SPUSBDataType 2>/dev/null)"
have(){ printf '%s' "$USB" | grep -qiE "$1"; }
CAM=1; BT=1
have 'camera|bison|chicony|sunplus|azurewave|0x5986|0x04f2|0x13d3|0x2b7e|0x1bcf' || CAM=0
have '0x8087|Bluetooth USB Host' || BT=0
say "Status: Kamera=$([ $CAM = 1 ] && echo DA || echo fehlt)  Bluetooth-USB=$([ $BT = 1 ] && echo DA || echo fehlt)"

if [ $CAM = 1 ] && [ $BT = 1 ]; then
  say ""
  say ">> Beide sind am USB sichtbar - der Reveal hat gegriffen. Nichts weiter noetig."
  say "   Bluetooth aktiv? (boot-arg -btlfxallowanyaddr ist gesetzt). Kamera in Photo Booth testen."
else
  # Interne EFI mounten + config.plist
  esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
  [ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
  diskutil mount "/dev/$esp" >/dev/null 2>&1
  mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
  CFG="$mp/EFI/OC/config.plist"; ACPIDIR="$mp/EFI/OC/ACPI"
  [ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }
  say "EFI: $mp"

  RESET_OK=1
  [ -f "$ACPIDIR/SSDT-RHUB-Reset.aml" ] || RESET_OK=0

  if $PB -c "Print :ACPI:Patch" "$CFG" 2>/dev/null | grep -q "RHUB reveal"; then
    # Rename ist schon drin, Ports aber weiter versteckt -> mehr als 15 Ports -> Mapping noetig.
    say ""
    say ">> Der Reveal-Patch ist bereits aktiv, Kamera/BT aber noch nicht sichtbar."
    say "   Das heisst: der Controller hat nach dem Reset MEHR als 15 Ports - jetzt muss"
    say "   einmalig gemappt werden (deaktiviert ungenutzte Ports, behaelt Kamera+BT)."
    say ""
    say "   1) SD-Karte einstecken + ein USB-Geraet in den USB-C-Port."
    say "   2) cd ~/USBMap && ./USBMap.command  ->  D (Discover)"
    say "      Jetzt tauchen Kamera (0x04f2/0x5986/0x1bcf) und BT (0x8087) als HS-Ports auf."
    say "      -> P (Edit & Create USBMap.kext): Kamera+BT+deine externen Ports behalten,"
    say "         Kamera/BT auf Typ 255 (internal), <=15 pro Controller. Kext bauen."
    say "   3) sudo bash usb-map-install.command ~/USBMap/Results/USBMap.kext  -> Neustart."
    say ""
    say "   Schick mir alternativ die D-Liste, dann sage ich dir die exakten Port-Nummern."
  elif [ $RESET_OK = 0 ]; then
    say "!! SSDT-RHUB-Reset.aml liegt nicht in der EFI. Bitte zuerst ssdt-install.command"
    say "   ausfuehren (RHUB-Reset), dann dieses Script erneut."
  else
    # Rename fuer beide RHUBs anlegen (macht den bereits installierten SSDT-Reset wirksam).
    cp "$CFG" "$CFG.finalbak" || { say "Backup fehlgeschlagen"; exit 1; }
    STA="$(printf '_STA' | base64)"; XSTA="$(printf 'XSTA' | base64)"
    cat > /tmp/rhub_patches.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>Base</key><string>\_SB.PCI0.XHC.RHUB</string>
        <key>BaseSkip</key><integer>0</integer>
        <key>Comment</key><string>RHUB reveal: _STA to XSTA (XHC)</string>
        <key>Count</key><integer>1</integer>
        <key>Enabled</key><true/>
        <key>Find</key><data>$STA</data>
        <key>Limit</key><integer>0</integer>
        <key>Mask</key><data></data>
        <key>OemTableId</key><data></data>
        <key>Replace</key><data>$XSTA</data>
        <key>ReplaceMask</key><data></data>
        <key>Skip</key><integer>0</integer>
        <key>TableLength</key><integer>0</integer>
        <key>TableSignature</key><data></data>
    </dict>
    <dict>
        <key>Base</key><string>\_SB.PCI0.RP09.PXSX.TBDU.XHC.RHUB</string>
        <key>BaseSkip</key><integer>0</integer>
        <key>Comment</key><string>RHUB reveal: _STA to XSTA (TB XHC)</string>
        <key>Count</key><integer>1</integer>
        <key>Enabled</key><true/>
        <key>Find</key><data>$STA</data>
        <key>Limit</key><integer>0</integer>
        <key>Mask</key><data></data>
        <key>OemTableId</key><data></data>
        <key>Replace</key><data>$XSTA</data>
        <key>ReplaceMask</key><data></data>
        <key>Skip</key><integer>0</integer>
        <key>TableLength</key><integer>0</integer>
        <key>TableSignature</key><data></data>
    </dict>
</array>
</plist>
EOF
    # sicherstellen, dass :ACPI:Patch existiert, dann anhaengen
    $PB -c "Print :ACPI:Patch" "$CFG" >/dev/null 2>&1 || $PB -c "Add :ACPI:Patch array" "$CFG" 2>/dev/null
    if $PB -c "Merge /tmp/rhub_patches.plist :ACPI:Patch" "$CFG" 2>/dev/null; then
      /usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
      if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
        say "- Reveal-Rename (XHC + TB-RHUB) eingetragen. config.plist gueltig."
        NEEDREBOOT=1
      else
        say "!! config.plist ungueltig -> Backup wird zurueckgespielt."
        cp "$CFG.finalbak" "$CFG"
      fi
    else
      say "!! Konnte Patch nicht eintragen -> keine Aenderung."
      cp "$CFG.finalbak" "$CFG"
    fi
  fi
fi

# ============================================================ ABSCHLUSS
RERUN='curl -fsSL "https://raw.githubusercontent.com/florianthepro/macos/claude/macos-usb-installer-exe-bfvxsy/scripts/final-fix.command" -o /tmp/final.command && sudo bash /tmp/final.command'
hr
if [ $NEEDREBOOT = 1 ]; then
  say ">> Jetzt NEU STARTEN. Danach denselben Befehl NOCHMAL ausfuehren"
  say "   (das Script prueft dann, ob Kamera+BT da sind, und sagt dir den Rest):"
  say ""
  say "   $RERUN"
  say ""
  say "   Rettung bei Boot-Problem: vom USB-Stick booten, dann"
  say "     cp \"$CFG.finalbak\" \"$CFG\""
else
  say ">> Tastatur ist gesetzt. Bei Kamera/BT: obige Meldung beachten."
fi

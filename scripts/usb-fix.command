#!/bin/bash
# usb-fix.command - AKTION: baut eine USBMap.kext, die die internen Ports (Kamera/BT/Fingerprint)
# als Typ 255 deklariert, damit macOS sie enumeriert (ueberschreibt Lenovos "nicht anschliessbar").
# Entfernt zugleich den wirkungslosen RHUB-Reset (SSDT + Renames). Sicher: Backup + plutil-Pruefung
# mit automatischem Rueckbau. Am Ende Neustart.
#   sudo bash usb-fix.command
# Portliste ist das Standard-T480-Layout (10x HS + externe SS), passend zu dem, was usb-test.command
# auf diesem Geraet gemeldet hat.
set -o pipefail
say(){ printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "Bitte mit sudo starten:  sudo bash \"$0\""; exit 1; }
PB=/usr/libexec/PlistBuddy

# interne EFI mounten
esp="$(diskutil list internal physical 2>/dev/null | awk '/^ +[0-9]+:.*EFI /{print $NF; exit}')"
[ -n "$esp" ] || { say "!! Interne EFI nicht gefunden."; exit 1; }
diskutil mount "/dev/$esp" >/dev/null 2>&1
mp="$(diskutil info "/dev/$esp" 2>/dev/null | awk -F': *' '/Mount Point/{print $2; exit}' | sed 's/[[:space:]]*$//')"
CFG="$mp/EFI/OC/config.plist"; KEXTS="$mp/EFI/OC/Kexts"; ACPIDIR="$mp/EFI/OC/ACPI"
[ -f "$CFG" ] || { say "!! config.plist nicht gefunden."; exit 1; }
[ -d "$KEXTS" ] || mkdir -p "$KEXTS"
say "EFI: $mp"
cp "$CFG" "$CFG.fixbak" || { say "Backup fehlgeschlagen"; exit 1; }
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1

# Modell + XHCI-Controller-Klasse ermitteln (fuer korrektes Matching, ohne Thunderbolt-Controller)
MODEL="$(sysctl -n hw.model 2>/dev/null)"; [ -n "$MODEL" ] || MODEL="MacBookPro14,1"
CLS="$(ioreg -w0 -l -c AppleUSBHostController 2>/dev/null | grep -oE 'AppleUSBXHCI[A-Za-z]+' | grep -viE 'AR$' | sort -u | head -1)"
[ -n "$CLS" ] || CLS="AppleUSBXHCISPTLP"
say "- Modell: $MODEL | Controller-Klasse: $CLS"

# --- Portliste dynamisch aus dem laufenden System ermitteln (generisch, alle Modelle) ---
# Extern = die Ports, die macOS schon enumeriert (Typ wird uebernommen).
# Intern = deklarierte, aber uebersprungene HS-Ports -> Typ 255. Interne SS werden ausgelassen.
# Fallback: bewaehrtes T480-Layout, falls die Erkennung nichts Brauchbares liefert.
PORTLINES="$(/usr/bin/python3 - 2>/dev/null <<'PY'
import subprocess, re
def sh(*a):
    try: return subprocess.run(a,capture_output=True,text=True,timeout=20).stdout
    except: return ""
acpi = sh('ioreg','-p','IOACPIPlane','-w0','-r','-n','XHC')
ports=[]; seen=set()
for name,addr in re.findall(r'-o ((?:HS|SS)\d\d)@([0-9a-fx]+)', acpi):
    try: n=int(addr,16)
    except: continue
    if name in seen: continue
    seen.add(name); ports.append((name,n))
svc = sh('ioreg','-w0','-l','-rc','AppleUSB20XHCIPort','-rc','AppleUSB30XHCIPort')
enum={}
for blk in re.split(r'\+-o ', svc):
    m=re.search(r'"(?:port|usb-port-number)"\s*=\s*<([0-9a-fA-F]{2})', blk)
    if not m: continue
    num=int(m.group(1),16)
    t=re.search(r'"(?:UsbConnector|usb-port-type)"\s*=\s*(\d+)', blk)
    enum[num]= int(t.group(1)) if t else 3
ext=[]; intr=[]
for name,n in ports:
    if n in enum:
        ty=enum[n]; ty = ty if ty in (0,3,8,9) else 3
        ext.append((name,n,ty))
    elif name.startswith('HS'):
        intr.append((name,n,255))
final=(ext+intr)[:15]
if len(final)>=6 and any(t==255 for _,_,t in final) and ext:
    for name,n,t in final: print(name,n,t)
PY
)"
names=(); nums=(); types=(); PORTCOUNT=0
if [ -n "$PORTLINES" ]; then
  while read -r nm nu ty; do [ -n "$nm" ] || continue; names+=("$nm"); nums+=("$nu"); types+=("$ty"); [ "$nu" -gt "$PORTCOUNT" ] && PORTCOUNT="$nu"; done <<< "$PORTLINES"
  say "- Ports dynamisch erkannt (${#names[@]} Stueck)."
else
  say "- Dynamische Erkennung ohne Ergebnis -> T480-Standardlayout."
  names=(HS01 HS02 HS03 HS04 HS05 HS06 HS07 HS08 HS09 HS10 SS01 SS02 SS04)
  nums=(  1    2    3    4    5    6    7    8    9   10   13   14   16 )
  types=( 3    3   255   9   255  255  255  255  255  255   3    3    9 )
  PORTCOUNT=16
fi

b64(){ printf "$(printf '\\x%02x\\x00\\x00\\x00' "$1")" | base64; }  # Portnummer -> 4-Byte-LE-Data (base64)

# --- USBMap.kext bauen ---
K="$KEXTS/USBMap.kext"; rm -rf "$K"; mkdir -p "$K/Contents"
{
cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.corpnewt.USBMap</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>USBMap</string>
    <key>CFBundlePackageType</key><string>KEXT</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>OSBundleRequired</key><string>Root</string>
    <key>IOKitPersonalities</key>
    <dict>
        <key>${MODEL}-XHC</key>
        <dict>
            <key>CFBundleIdentifier</key><string>com.apple.driver.AppleUSBHostMergeProperties</string>
            <key>IOClass</key><string>AppleUSBHostMergeProperties</string>
            <key>IONameMatch</key><string>XHC</string>
            <key>IOProviderClass</key><string>${CLS}</string>
            <key>model</key><string>${MODEL}</string>
            <key>IOProviderMergeProperties</key>
            <dict>
                <key>kUSBMuxEnabled</key><true/>
                <key>port-count</key><data>$(b64 $PORTCOUNT)</data>
                <key>ports</key>
                <dict>
HEAD
for i in "${!names[@]}"; do
  d="$(b64 "${nums[$i]}")"
  cat <<PORT
                    <key>${names[$i]}</key>
                    <dict>
                        <key>UsbConnector</key><integer>${types[$i]}</integer>
                        <key>port</key><data>${d}</data>
                        <key>usb-port-number</key><data>${d}</data>
                        <key>usb-port-type</key><integer>${types[$i]}</integer>
                    </dict>
PORT
done
cat <<'TAIL'
                </dict>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
TAIL
} > "$K/Contents/Info.plist"

if /usr/bin/plutil -lint "$K/Contents/Info.plist" >/dev/null 2>&1; then
  say "- USBMap.kext erzeugt ($(printf '%s ' "${names[@]}"))."
else
  say "!! Erzeugte Info.plist ungueltig -> Abbruch, keine Aenderung."; rm -rf "$K"; exit 1
fi

# --- USBMap.kext in Kernel:Add eintragen (codeless, Dublettenschutz) ---
if $PB -c "Print :Kernel:Add" "$CFG" 2>/dev/null | grep -q "BundlePath = USBMap.kext\$"; then
  say "- USBMap.kext war schon in Kernel:Add."
else
  i="$(/usr/bin/plutil -extract Kernel.Add raw -o - "$CFG" 2>/dev/null)"; case "$i" in ''|*[!0-9]*) i="";; esac
  [ -n "$i" ] && $PB -c "Add :Kernel:Add:$i dict" -c "Add :Kernel:Add:$i:Arch string x86_64" \
    -c "Add :Kernel:Add:$i:BundlePath string USBMap.kext" -c "Add :Kernel:Add:$i:Comment string USB port map" \
    -c "Add :Kernel:Add:$i:Enabled bool true" -c "Add :Kernel:Add:$i:ExecutablePath string " \
    -c "Add :Kernel:Add:$i:MaxKernel string " -c "Add :Kernel:Add:$i:MinKernel string " \
    -c "Add :Kernel:Add:$i:PlistPath string Contents/Info.plist" "$CFG" && say "- USBMap.kext in Kernel:Add eingetragen."
fi

# --- wirkungslosen RHUB-Reset entfernen (SSDT + Renames) ---
n="$(/usr/bin/plutil -extract ACPI.Add raw -o - "$CFG" 2>/dev/null)"
for ((j=n-1;j>=0;j--)); do
  p="$($PB -c "Print :ACPI:Add:$j:Path" "$CFG" 2>/dev/null)"
  case "$p" in SSDT-RHUB-Reset.aml|SSDT-USB-Reset.aml) $PB -c "Delete :ACPI:Add:$j" "$CFG" 2>/dev/null;; esac
done
n="$(/usr/bin/plutil -extract ACPI.Patch raw -o - "$CFG" 2>/dev/null)"
for ((j=n-1;j>=0;j--)); do
  c="$($PB -c "Print :ACPI:Patch:$j:Comment" "$CFG" 2>/dev/null)"
  case "$c" in *"RHUB reveal"*) $PB -c "Delete :ACPI:Patch:$j" "$CFG" 2>/dev/null;; esac
done
rm -f "$ACPIDIR/SSDT-RHUB-Reset.aml" "$ACPIDIR/SSDT-USB-Reset.aml"
say "- RHUB-Reset (SSDT + Renames) entfernt."

# --- XhciPortLimit sicher aus ---
$PB -c "Set :Kernel:Quirks:XhciPortLimit false" "$CFG" 2>/dev/null

# --- validieren -> bei Fehler Backup zurueck ---
/usr/bin/plutil -convert xml1 "$CFG" >/dev/null 2>&1
if /usr/bin/plutil -lint "$CFG" >/dev/null 2>&1; then
  say ""
  say "== OK. Es wird in 8 Sekunden NEU GESTARTET. Danach sollten Kamera + Bluetooth da sein."
  say "   Pruefen:  sudo bash usb-test.command   (oder 'Ueber diesen Mac > USB')."
  say "   Rettung bei Problem: vom USB-Stick booten, dann"
  say "     cp \"$CFG.fixbak\" \"$CFG\"  und $KEXTS/USBMap.kext loeschen."
  sync
  for s in 8 7 6 5 4 3 2 1; do printf '\r  Neustart in %s ... ' "$s"; sleep 1; done; echo
  reboot
else
  say "!! config.plist ungueltig -> Backup wird zurueckgespielt (keine Aenderung)."
  cp "$CFG.fixbak" "$CFG"; rm -rf "$K"; exit 1
fi

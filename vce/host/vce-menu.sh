#!/usr/bin/env bash
# vce-menu - das VM-Menue des VCE-Hosts (laeuft auf Konsole 1).
# Jede VM bekommt: virtuelle Platte (qcow2), EIGENES virtuelles EFI (OVMF-NVRAM-Kopie),
# virtio-Netz. Gast-Bootloader landen damit im virtuellen EFI - nie im echten.
set -u
CONF=/etc/vce/vce.conf; [ -f "$CONF" ] && . "$CONF"; SERVER="${SERVER:-}"
D=/var/lib/vce; DISKS="$D/disks"; ISOS="$D/isos"; NVRAM="$D/nvram"
mkdir -p "$DISKS" "$ISOS" "$NVRAM"

# OVMF-Pfade (Debian: 4M-Varianten bevorzugt)
CODE=""; VARS=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$c" ] && { CODE="$c"; break; }; done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$v" ] && { VARS="$v"; break; }; done

die(){ dialog --msgbox "$1" 8 60; }
have_kvm(){ [ -e /dev/kvm ]; }

vm_list(){ ls -1 "$DISKS" 2>/dev/null | sed 's/\.qcow2$//'; }

pick_vm(){ # $1 = Titel; echo Name oder leer
  local items=() n
  while IFS= read -r n; do [ -n "$n" ] && items+=("$n" ""); done <<< "$(vm_list)"
  [ ${#items[@]} -gt 0 ] || { die "Keine VM vorhanden."; return 1; }
  dialog --stdout --menu "$1" 18 60 10 "${items[@]}"
}

pick_iso(){ # echo Pfad oder leer (Abbruch)
  local items=("(ohne ISO)" "nur Platte booten") f
  while IFS= read -r f; do [ -n "$f" ] && items+=("$f" ""); done <<< "$(ls -1 "$ISOS" 2>/dev/null)"
  local sel; sel="$(dialog --stdout --menu "ISO waehlen" 18 70 10 "${items[@]}")" || return 1
  [ "$sel" = "(ohne ISO)" ] && { echo ""; return 0; }
  echo "$ISOS/$sel"
}

fetch_iso(){
  [ -n "$SERVER" ] || { die "Kein Server konfiguriert (/etc/vce/vce.conf)."; return; }
  local name; name="$(dialog --stdout --inputbox "Dateiname auf dem Server unter /vce/isos/\n(z. B. ubuntu-24.04.iso)" 10 60)" || return
  [ -n "$name" ] || return
  clear; echo "Lade $SERVER/vce/isos/$name ..."
  if curl -fL --progress-bar "$SERVER/vce/isos/$name" -o "$ISOS/$name"; then
    die "Geladen: $name"
  else rm -f "$ISOS/$name"; die "Download fehlgeschlagen: $name"; fi
}

create_vm(){
  [ -n "$CODE" ] && [ -n "$VARS" ] || { die "OVMF fehlt (apt install ovmf)."; return; }
  local name gb ram cpu
  name="$(dialog --stdout --inputbox "Name der VM (a-z, 0-9, -):" 8 50)" || return
  printf '%s' "$name" | grep -qE '^[a-z0-9-]{1,32}$' || { die "Ungueltiger Name."; return; }
  [ -f "$DISKS/$name.qcow2" ] && { die "VM '$name' existiert schon."; return; }
  gb="$(dialog --stdout --inputbox "Groesse der virtuellen Platte (GB):" 8 50 "64")" || return
  printf '%s' "$gb" | grep -qE '^[0-9]{1,4}$' || { die "Ungueltige Groesse."; return; }
  ram="$(dialog --stdout --inputbox "Arbeitsspeicher (MB):" 8 50 "4096")" || return
  cpu="$(dialog --stdout --inputbox "CPU-Kerne:" 8 50 "2")" || return
  qemu-img create -q -f qcow2 "$DISKS/$name.qcow2" "${gb}G" || { die "qcow2 fehlgeschlagen."; return; }
  cp "$VARS" "$NVRAM/$name.fd"   # eigenes virtuelles EFI-NVRAM fuer diese VM
  printf 'RAM=%s\nCPU=%s\n' "$ram" "$cpu" > "$D/$name.conf"
  die "VM '$name' angelegt (${gb} GB Platte + eigenes virtuelles EFI).\nJetzt 'VM starten' und eine Install-ISO waehlen."
}

start_vm(){
  local name; name="$(pick_vm "VM starten")" || return
  [ -n "$name" ] || return
  local RAM=4096 CPU=2; [ -f "$D/$name.conf" ] && . "$D/$name.conf"
  local iso; iso="$(pick_iso)" || return
  local disp accel=() dispargs=()
  disp="$(dialog --stdout --menu "Anzeige" 12 60 4 \
    kms  "Vollbild auf dieser Konsole (empfohlen)" \
    vnc  "VNC :0 (von anderem Rechner ansehen)" \
    text "Textkonsole (nur Text-Gaeste)")" || return
  have_kvm && accel=(-enable-kvm -cpu host) || accel=(-cpu qemu64)
  case "$disp" in
    kms)  export SDL_VIDEODRIVER=kmsdrm; dispargs=(-display sdl -vga virtio) ;;
    vnc)  dispargs=(-display none -vnc :0 -vga virtio) ;;
    text) dispargs=(-display curses) ;;
  esac
  local cd=(); [ -n "$iso" ] && cd=(-cdrom "$iso")
  clear
  echo "VCE: starte '$name' (RAM ${RAM}M, ${CPU} CPU) - Beenden: Gast herunterfahren."
  [ "$disp" = vnc ] && echo "VNC erreichbar auf Port 5900 dieser Maschine."
  qemu-system-x86_64 "${accel[@]}" -M q35 -smp "$CPU" -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,file="$NVRAM/$name.fd" \
    -drive if=virtio,format=qcow2,file="$DISKS/$name.qcow2" \
    "${cd[@]}" -nic user,model=virtio-net-pci "${dispargs[@]}"
  echo; read -r -p "VM beendet - Enter fuer Menue " _ || true
}

delete_vm(){
  local name; name="$(pick_vm "VM LOESCHEN (unwiderruflich)")" || return
  [ -n "$name" ] || return
  dialog --yesno "VM '$name' inkl. virtueller Platte wirklich loeschen?" 8 55 || return
  rm -f "$DISKS/$name.qcow2" "$NVRAM/$name.fd" "$D/$name.conf"
  die "VM '$name' geloescht."
}

# Kiosk-Modus: die Standard-VM startet beim Einschalten automatisch in Vollbild -
# der Nutzer sieht nie VCE, nur sein OS. VM beenden -> Menue erscheint.
set_autostart(){
  local name; name="$(pick_vm "Standard-VM (startet beim Einschalten automatisch)")" || {
    dialog --yesno "Autostart AUSSCHALTEN?" 7 45 && { sed -i '/^AUTOSTART=/d' "$CONF" 2>/dev/null; die "Autostart aus."; }
    return; }
  [ -n "$name" ] || return
  sed -i '/^AUTOSTART=/d' "$CONF" 2>/dev/null
  printf 'AUTOSTART=%s\n' "$name" >> "$CONF"
  die "'$name' startet ab jetzt beim Einschalten automatisch (Vollbild).\nZum Menue: VM herunterfahren."
}

run_vm(){ # $1=Name - Start ohne Rueckfragen (Kiosk), Vollbild auf der Konsole
  local name="$1" RAM=4096 CPU=2
  [ -f "$D/$name.conf" ] && . "$D/$name.conf"
  local accel=(); have_kvm && accel=(-enable-kvm -cpu host) || accel=(-cpu qemu64)
  export SDL_VIDEODRIVER=kmsdrm
  qemu-system-x86_64 "${accel[@]}" -M q35 -smp "$CPU" -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file="$CODE" \
    -drive if=pflash,format=raw,file="$NVRAM/$name.fd" \
    -drive if=virtio,format=qcow2,file="$DISKS/$name.qcow2" \
    -nic user,model=virtio-net-pci -display sdl -vga virtio
}

autostart_check(){
  # Bei JEDEM Boot: kurzes Fenster - Taste druecken = Auswahl-Menue, sonst startet
  # das Standard-OS automatisch. (Nur beim ersten Menuestart nach dem Boot.)
  [ -n "${AUTOSTART:-}" ] || return 0
  [ -f /run/vce-autostarted ] && return 0
  touch /run/vce-autostarted 2>/dev/null || true
  [ -f "$DISKS/$AUTOSTART.qcow2" ] || return 0
  clear
  echo "=================================================="
  echo "  VCE   Standard-OS:  $AUTOSTART"
  echo "=================================================="
  echo "  Startet automatisch in 3 Sekunden."
  echo "  BELIEBIGE TASTE druecken fuer Boot-/OS-Auswahl."
  if read -r -s -n 1 -t 3 _ 2>/dev/null; then
    return 0            # Taste gedrueckt -> Auswahl-Menue anzeigen
  fi
  run_vm "$AUTOSTART" || true   # Timeout -> Standard-OS starten (Menue nach Beenden)
}

info(){
  local k="nein"; have_kvm && k="ja"
  die "VCE-Host\n\nServer:  ${SERVER:-'-'}\nKVM:     $k\nVMs:     $(vm_list | tr '\n' ' ')\nDisks:   $DISKS\nISOs:    $ISOS\nEFI-NVRAM: $NVRAM"
}

command -v dialog >/dev/null || { echo "dialog fehlt (apt install dialog)"; exec bash; }
autostart_check
while :; do
  sel="$(dialog --stdout --no-cancel --menu "VCE - Virtual Compatible EFI  (Host)" 18 62 10 \
    start  "VM starten" \
    new    "Neue VM anlegen" \
    auto   "Standard-VM festlegen (Autostart beim Einschalten)" \
    iso    "ISO vom Server laden" \
    del    "VM loeschen" \
    info   "Status" \
    shell  "Shell (Experten)" \
    reboot "Neustart" \
    off    "Ausschalten")"
  case "$sel" in
    start) start_vm ;;
    new)   create_vm ;;
    auto)  set_autostart ;;
    iso)   fetch_iso ;;
    del)   delete_vm ;;
    info)  info ;;
    shell) clear; echo "exit -> zurueck ins Menue"; bash || true ;;
    reboot) systemctl reboot ;;
    off)   systemctl poweroff ;;
  esac
done

#!/usr/bin/env bash
#
# macOS USB Setup (Linux) - erstellt einen bootfaehigen macOS-Installations-Stick.
# Gleicher Ablauf wie setup.exe: Hardware-Scan -> lauffaehige Versionen -> Auswahl
# -> USB waehlen -> schreiben. Eigene Implementierung; extern sind nur die Daten
# selbst (macOS-Recovery von Apple, OpenCore/Kext-Binaries von ihren Projekten).
#
set -euo pipefail
export LC_ALL=C

OC_VERSION="1.0.7"
LILU_VERSION="1.7.1"
VSMC_VERSION="1.3.7"
WEG_VERSION="1.7.0"
VOODOOPS2_VERSION="2.3.7"
INTELMAUSI_VERSION="1.0.8"
AIRPORTITLWM_VERSION="v2.3.0"
ALC_VERSION="1.9.2"
IBF_VERSION="v2.4.0"      # IntelBluetoothFirmware (+ IntelBTPatcher) - Intel-BT
BRCM_VERSION="2.7.2"      # BrcmPatchRAM-Release liefert BlueToolFixup.kext (macOS 12+)

readonly OSRECOVERY="http://osrecovery.apple.com"
readonly UA="InternetRecovery/1.0"
readonly MLB_ZERO="00000000000000000"

# name : marketing : recoveryVersion : darwin : board-id : os-type : smbiosDesktop : smbiosLaptop
readonly RELEASES=(
  "Tahoe:26:latest:25:Mac-27AD2F918AE68F61:latest:MacPro7,1:MacBookPro16,1"
  "Sequoia:15:15.7.4:24:Mac-0CFF9C7C2B63DF8D:default:MacPro7,1:MacBookPro16,1"
  "Sonoma:14:14.8.4:23:Mac-827FAC58A8FDFA22:default:MacPro7,1:MacBookPro16,1"
  "Ventura:13:13.7.8:22:Mac-EE2EBD4B90B839A8:default:iMacPro1,1:MacBookPro16,1"
  "Monterey:12:12.7.6:21:Mac-9AE82516C7C6B903:default:iMacPro1,1:MacBookPro15,1"
  "Big-Sur:11:11.7.11:20:Mac-BE0E8AC46FE800CC:default:iMacPro1,1:MacBookPro15,1"
  "Catalina:10.15:10.15.8:19:Mac-66F35F19FE2A0D05:default:iMacPro1,1:MacBookPro14,1"
  "High-Sierra:10.13:10.13.6:17:Mac-942452F5819B1C1B:default:iMac14,2:MacBookPro11,1"
)

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; RST=""
fi

LOG="${TMPDIR:-/tmp}/macos-usb-setup-$(date +%Y%m%d-%H%M%S).log"
WORK=""; MNT=""; DATA_MNT=""; OFFLINE=0

log()  { printf '%s\n' "$*" >>"$LOG"; }
step() { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; log "STEP $*"; }
info() { printf '    %s\n' "$*"; log "INFO $*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; log "WARN $*"; }

# die <stufe> <meldung> [empfehlung]
die() {
  printf '\n%s[Fehler: %s]%s %s\n' "$RED" "$1" "$RST" "$2" >&2
  [[ -n "${3:-}" ]] && printf '    Empfehlung: %s\n' "$3" >&2
  printf '    Protokoll: %s\n' "$LOG" >&2
  log "FEHLER [$1] $2"
  exit 1
}

cleanup() {
  [[ -n "$MNT" && -d "$MNT" ]] && { sync || true; umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
  [[ -n "$DATA_MNT" && -d "$DATA_MNT" ]] && { sync || true; umount "$DATA_MNT" 2>/dev/null || true; rmdir "$DATA_MNT" 2>/dev/null || true; }
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'die Unerwartet "Abbruch in Zeile $LINENO." "Protokoll pruefen."' ERR

require_root() {
  if [[ $EUID -ne 0 ]]; then
    info "Root-Rechte erforderlich (Partitionieren/Formatieren) - starte via sudo neu."
    exec sudo -E bash "$0" "$@"
  fi
}

require_tools() {
  local missing=()
  for c in curl lsblk lscpu lspci sgdisk mkfs.vfat wipefs partprobe unzip python3 findmnt; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    die Voraussetzungen "Fehlende Programme: ${missing[*]}." \
      "Installieren, z. B.: Debian/Ubuntu 'apt install curl util-linux pciutils gdisk dosfstools python3', Fedora 'dnf install ...', Arch 'pacman -S ...'."
  fi
}

# ---------------------------------------------------------------- Hardware-Scan

CPU_VENDOR=""; CPU_FAMILY=0; CPU_MODEL=0; CPU_CORES=1; CPU_BRAND=""
GPU_VEN=(); GPU_DEV=(); HAS_INTEL_IGPU=0; HAS_MODERN_NVIDIA=0; INTEL_IGPU_DEV=""
FIRMWARE="unknown"; MEM_BYTES=0; IS_LAPTOP=0

scan_hardware() {
  step "Hardware wird analysiert"

  local vendor family model cps sockets
  vendor=$(lscpu | awk -F: '/^Vendor ID/{gsub(/^[ \t]+/,"",$2);print $2;exit}')
  family=$(lscpu | awk -F: '/^CPU family/{gsub(/[ \t]/,"",$2);print $2;exit}')
  model=$(lscpu  | awk -F: '/^Model:/{gsub(/[ \t]/,"",$2);print $2;exit}')
  cps=$(lscpu    | awk -F: '/^Core\(s\) per socket/{gsub(/[ \t]/,"",$2);print $2;exit}')
  sockets=$(lscpu| awk -F: '/^Socket\(s\)/{gsub(/[ \t]/,"",$2);print $2;exit}')
  CPU_BRAND=$(lscpu | awk -F: '/^Model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}')

  case "$vendor" in
    GenuineIntel) CPU_VENDOR="intel" ;;
    AuthenticAMD) CPU_VENDOR="amd" ;;
    *)            CPU_VENDOR="unknown" ;;
  esac
  CPU_FAMILY=${family:-0}; CPU_MODEL=${model:-0}
  CPU_CORES=$(( ${cps:-1} * ${sockets:-1} )); (( CPU_CORES > 0 )) || CPU_CORES=$(nproc)
  [[ -n "$CPU_BRAND" ]] || CPU_BRAND="$vendor CPU"
  info "CPU: ${CPU_BRAND} (Family ${CPU_FAMILY}, Model ${CPU_MODEL}, ${CPU_CORES} Kerne)"

  local line ids ven dev
  while IFS= read -r line; do
    ids=$(grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' <<<"$line" | tail -n1)
    [[ -n "$ids" ]] || continue
    ven=${ids%%:*}; dev=${ids##*:}
    ven=${ven,,}; dev=${dev,,}
    GPU_VEN+=("$ven"); GPU_DEV+=("$dev")
    info "GPU: [$ven:$dev] ${line#*: }"
    if [[ "$ven" == "8086" ]]; then HAS_INTEL_IGPU=1; [[ -z "$INTEL_IGPU_DEV" ]] && INTEL_IGPU_DEV="$dev"; fi
    if [[ "$ven" == "10de" && $((16#$dev)) -ge $((16#1340)) ]]; then HAS_MODERN_NVIDIA=1; fi
  done < <(lspci -nn | grep -iE 'VGA compatible controller|3D controller|Display controller')

  local chassis="" ; [[ -r /sys/class/dmi/id/chassis_type ]] && chassis=$(cat /sys/class/dmi/id/chassis_type)
  if [[ "$chassis" =~ ^(8|9|10|11|14|30|31|32)$ ]] || [[ "$CPU_BRAND" =~ [0-9]{3,5}[[:space:]]*(U|H|HQ|HK|HX|HS|Y|MQ|G7)\b ]]; then
    IS_LAPTOP=1
  fi

  [[ -d /sys/firmware/efi ]] && FIRMWARE="uefi" || FIRMWARE="legacy"
  info "Firmware: ${FIRMWARE}"

  local memkb; memkb=$(awk '/^MemTotal/{print $2;exit}' /proc/meminfo)
  MEM_BYTES=$(( ${memkb:-0} * 1024 ))
  info "RAM: $(( MEM_BYTES / 1073741824 )) GB"
}

# --------------------------------------------------------------- Kompatibilitaet

# level_from <darwin> <min> <sup> <exp> -> supported|experimental|unsupported
level_from() {
  local d=$1 min=$2 sup=$3 exp=$4
  if   (( d < min ));               then echo unsupported
  elif (( sup >= 0 && d <= sup ));  then echo supported
  elif (( exp >= 0 && d <= exp ));  then echo experimental
  else echo unsupported; fi
}
rank() { case "$1" in supported) echo 0;; experimental) echo 1;; *) echo 2;; esac; }
worst() { (( $(rank "$1") >= $(rank "$2") )) && echo "$1" || echo "$2"; }

C_SUP=0; C_EXP=0; C_NOTE=""; C_ALWAYS=0
cpu_window() {
  C_NOTE=""; C_ALWAYS=0
  if [[ "$CPU_VENDOR" == "amd" ]]; then
    if (( CPU_FAMILY >= 23 )); then
      C_SUP=-1; C_EXP=25; C_ALWAYS=1
      C_NOTE="AMD-Ryzen: benoetigt AMD-Vanilla-Kernel-Patches (im EFI enthalten)"
    else
      C_SUP=-1; C_EXP=-1; C_ALWAYS=1; C_NOTE="AMD ohne Ryzen wird nicht unterstuetzt"
    fi
    return
  fi
  if [[ "$CPU_VENDOR" != "intel" || "$CPU_FAMILY" -ne 6 ]]; then
    C_SUP=-1; C_EXP=25; C_ALWAYS=1; C_NOTE="CPU nicht klassifiziert"; return
  fi
  case "$CPU_MODEL" in
    42|58)            C_SUP=21; C_EXP=21; C_NOTE="Sandy/Ivy Bridge: maximal Monterey" ;;
    60|61|69|70|71)   C_SUP=24; C_EXP=25; C_NOTE="Haswell/Broadwell: Tahoe nur experimentell" ;;
    78|94|85|165|166) C_SUP=25; C_EXP=25; C_NOTE="" ;;
    142|158)          C_SUP=25; C_EXP=25; C_NOTE="" ;;
    125|126)          C_SUP=25; C_EXP=25; C_ALWAYS=1; C_NOTE="Ice Lake: auf Desktop ggf. CPUFriend" ;;
    140|141)          C_SUP=25; C_EXP=25; C_ALWAYS=1; C_NOTE="Tiger Lake: auf Desktop ggf. CPUFriend" ;;
    151|154|183)      C_SUP=-1; C_EXP=25; C_ALWAYS=1; C_NOTE="Hybrid-CPU: E-Cores ggf. deaktivieren" ;;
    *)                if (( CPU_MODEL <= 47 )); then C_SUP=18; C_EXP=18; C_NOTE="alte Intel-CPU (maximal Mojave)";
                      else C_SUP=-1; C_EXP=25; C_ALWAYS=1; C_NOTE="Intel-CPU nicht klassifiziert"; fi ;;
  esac
}

G_MIN=0; G_SUP=0; G_EXP=0; G_NOTE=""; G_ALWAYS=0
gpu_adapter_window() {
  local ven=$1 dec=$((16#$2))
  G_MIN=0; G_SUP=-1; G_EXP=25; G_NOTE=""; G_ALWAYS=0
  case "$ven" in
    10de)
      if (( dec >= 16#1340 )); then G_SUP=17; G_EXP=17; G_ALWAYS=1; G_NOTE="Nvidia: keine Treiber ab Mojave";
      else G_SUP=20; G_EXP=21; G_NOTE="Nvidia Kepler: maximal Big Sur"; fi ;;
    1002|1022)
      if   (( (dec>=16#15D8 && dec<=16#15DF) || (dec>=16#1636 && dec<=16#164F) || (dec>=16#1680 && dec<=16#168F) || dec==16#15BF || dec==16#15C8 )); then G_SUP=-1; G_EXP=-1; G_ALWAYS=1; G_NOTE="AMD-APU-Grafik (Vega/RDNA integriert): keine macOS-Treiber"
      elif (( dec >= 16#7440 && dec <= 16#745F )); then G_SUP=-1; G_EXP=-1; G_ALWAYS=1; G_NOTE="AMD Navi3x (RX 7000): keine Treiber"
      elif (( dec >= 16#73A0 && dec <= 16#743F )); then G_MIN=21; G_SUP=25; G_EXP=25; G_NOTE="AMD Navi2x (RX 6000): ab Monterey"
      elif (( dec >= 16#7310 && dec <= 16#739F )); then G_MIN=19; G_SUP=25; G_EXP=25; G_NOTE="AMD Navi1x (RX 5000): ab Catalina"
      elif (( (dec>=16#67C0 && dec<=16#67FF) || (dec>=16#6980 && dec<=16#699F) || (dec>=16#6860 && dec<=16#687F) || (dec>=16#69A0 && dec<=16#69AF) || (dec>=16#66A0 && dec<=16#66BF) )); then G_SUP=25; G_EXP=25
      else G_SUP=21; G_EXP=21; G_NOTE="Alte AMD-GCN: maximal Monterey"; fi ;;
    8086)
      # Ceilings mirror the C# IntelIgpuCatalog (most-specific ranges first).
      if   (( dec >= 16#0100 && dec <= 16#014F )); then G_SUP=17; G_EXP=17; G_NOTE="Intel HD 3000 (Sandy Bridge): maximal High Sierra"
      elif (( dec >= 16#0150 && dec <= 16#016F )); then G_SUP=20; G_EXP=20; G_NOTE="Intel HD 4000 (Ivy Bridge): maximal Big Sur"
      elif (( dec >= 16#0400 && dec <= 16#0D3F )); then G_SUP=21; G_EXP=21; G_NOTE="Intel HD 4400/4600/5000 (Haswell): maximal Monterey"
      elif (( dec >= 16#1600 && dec <= 16#163F )); then G_SUP=21; G_EXP=21; G_NOTE="Intel HD 5500/6000 (Broadwell): maximal Monterey"
      elif (( dec >= 16#1900 && dec <= 16#193F )); then G_SUP=21; G_EXP=22; G_NOTE="Intel HD 5xx (Skylake): maximal Monterey"
      elif (( dec >= 16#5900 && dec <= 16#593F )); then G_SUP=22; G_EXP=23; G_NOTE="Intel HD/UHD 620/630 (Kaby Lake): maximal Ventura"
      elif (( dec >= 16#3E00 && dec <= 16#3EFF )); then G_SUP=22; G_EXP=23; G_NOTE="Intel UHD 630 (Coffee Lake): maximal Ventura"
      elif (( dec >= 16#9B00 && dec <= 16#9BFF )); then G_SUP=23; G_EXP=24; G_NOTE="Intel UHD 630 (Comet Lake): maximal Sonoma"
      elif (( dec >= 16#8A50 && dec <= 16#8A7F )); then G_SUP=23; G_EXP=24; G_NOTE="Intel Iris Plus (Ice Lake): maximal Sonoma"
      else G_SUP=-1; G_EXP=25; G_ALWAYS=1; G_NOTE="Intel-iGPU nicht klassifiziert - nur VESA (unbeschleunigt)"; fi ;;
    *) G_SUP=-1; G_EXP=25; G_ALWAYS=1; G_NOTE="Grafik-Hersteller unbekannt" ;;
  esac
}

# evaluate_release <darwin> -> sets R_LEVEL and R_NOTES (newline separated)
R_LEVEL=""; R_NOTES=""
evaluate_release() {
  local d=$1; local notes="" cpu_level gpu_level level="unsupported"

  cpu_window
  cpu_level=$(level_from "$d" 0 "$C_SUP" "$C_EXP")
  if [[ -n "$C_NOTE" && ( "$C_ALWAYS" -eq 1 || "$cpu_level" != "supported" ) ]]; then notes+="$C_NOTE"$'\n'; fi

  if (( ${#GPU_VEN[@]} == 0 )); then
    gpu_level="unsupported"; notes+="Keine Grafikeinheit erkannt"$'\n'
  else
    gpu_level="unsupported"; local best_note="" i l
    for i in "${!GPU_VEN[@]}"; do
      gpu_adapter_window "${GPU_VEN[$i]}" "${GPU_DEV[$i]}"
      l=$(level_from "$d" "$G_MIN" "$G_SUP" "$G_EXP")
      if (( $(rank "$l") < $(rank "$gpu_level") )); then
        gpu_level="$l"
        if [[ -n "$G_NOTE" && ( "$G_ALWAYS" -eq 1 || "$l" != "supported" ) ]]; then best_note="$G_NOTE"; else best_note=""; fi
      fi
    done
    [[ -n "$best_note" ]] && notes+="$best_note"$'\n'
    if (( HAS_MODERN_NVIDIA == 1 && d >= 18 )); then
      notes+="Nvidia: keine Treiber ab Mojave"$'\n'
      [[ "$gpu_level" != "unsupported" && "$HAS_INTEL_IGPU" -eq 1 ]] && notes+="nur iGPU headless nutzbar"$'\n'
    fi
  fi

  level=$(worst "$cpu_level" "$gpu_level")

  if [[ "$FIRMWARE" == "legacy" ]]; then
    notes+="Legacy-BIOS erkannt: im UEFI-Modus booten (CSM deaktivieren)"$'\n'
    [[ "$level" == "supported" ]] && level="experimental"
  fi
  if (( MEM_BYTES > 0 && MEM_BYTES < 2147483648 )); then
    notes+="Weniger als 2 GB RAM: fuer die Installation nicht ausreichend"$'\n'; level="unsupported"
  elif (( MEM_BYTES > 0 && MEM_BYTES < 4294967296 )); then
    notes+="Weniger als 4 GB RAM: Installation kann langsam sein"$'\n'
  fi

  R_LEVEL="$level"; R_NOTES="${notes%$'\n'}"
}

# ----------------------------------------------------------------- Auswahl (TUI)

SEL_IDX=-1
choose_version() {
  step "Lauffaehige macOS-Versionen"
  local -a options=()
  local rec name marketing darwin badge
  for rec in "${RELEASES[@]}"; do
    IFS=: read -r name marketing _ darwin _ _ _ _ <<<"$rec"
    evaluate_release "$darwin"
    [[ "$R_LEVEL" == "unsupported" ]] && continue
    [[ "$R_LEVEL" == "supported" ]] && badge="${GRN}empfohlen${RST}" || badge="${YEL}experimentell${RST}"
    options+=("$rec")
    printf '  %s%2d%s  macOS %-12s %-6s [%s]\n' "$BOLD" "${#options[@]}" "$RST" "$name" "$marketing" "$badge"
    [[ -n "$R_NOTES" ]] && while IFS= read -r n; do printf '        %s- %s%s\n' "$DIM" "$n" "$RST"; done <<<"$R_NOTES"
  done
  (( ${#options[@]} )) || die Kompatibilitaet "Fuer diese Hardware wurde keine lauffaehige macOS-Version gefunden." \
    "Grafik/CPU pruefen; ggf. andere Hardware verwenden."

  local pick
  while :; do
    read -r -p "Version waehlen [1-${#options[@]}]: " pick </dev/tty
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#options[@]} )) && break
    warn "Ungueltige Eingabe."
  done
  SELECTED_RELEASE="${options[$((pick-1))]}"
}

choose_mode() {
  OFFLINE=0
  local darwin; IFS=: read -r _ _ _ darwin _ _ _ _ <<<"$SELECTED_RELEASE"
  (( darwin >= 20 )) || return 0   # Voll-Installer (InstallAssistant.pkg) erst ab Big Sur
  step "Installer-Typ"
  printf '  %sOffline%s legt den KOMPLETTEN macOS-Installer (~12 GB) auf den Stick -\n' "$BOLD" "$RST"
  printf '  die Installation braucht dann KEIN Internet. Erfordert einen 32-GB-Stick.\n\n'
  printf '    1) Online  - kleiner Stick, laedt macOS beim Installieren von Apple (Standard)\n'
  printf '    2) Offline - kompletter Installer auf dem Stick, kein Netz beim Installieren\n\n'
  local pick; read -r -p "  Auswahl [1]: " pick </dev/tty || pick=1
  [[ "$pick" == "2" ]] && OFFLINE=1
  if (( OFFLINE == 1 )); then info "Offline-Installer gewaehlt"; else info "Online-Installer gewaehlt"; fi
}

SEL_DEV=""; SEL_SIZE=""
choose_usb() {
  step "USB-Datentraeger waehlen"
  local root_disk; root_disk=$(lsblk -no pkname "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -n1)

  local -a devs=() sizes=() models=()
  local name size model tran
  while IFS=$'\t' read -r name size model tran; do
    [[ "$tran" == "usb" ]] || continue
    [[ "$name" == "$root_disk" ]] && continue
    devs+=("/dev/$name"); sizes+=("$size"); models+=("${model:-USB-Datentraeger}")
  done < <(lsblk -dn -o NAME,SIZE,MODEL,TRAN --raw 2>/dev/null | tr -s ' ' '\t')

  if (( ${#devs[@]} == 0 )); then
    die USB "Kein USB-Datentraeger gefunden." "Stick einstecken und Setup erneut starten."
  fi

  printf '  %sAchtung: Der gewaehlte Datentraeger wird vollstaendig geloescht.%s\n' "$YEL" "$RST"
  local i
  for i in "${!devs[@]}"; do
    printf '  %s%2d%s  %-10s %-8s %s\n' "$BOLD" "$((i+1))" "$RST" "${devs[$i]}" "${sizes[$i]}" "${models[$i]}"
  done

  local pick
  while :; do
    read -r -p "USB waehlen [1-${#devs[@]}]: " pick </dev/tty
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#devs[@]} )) && break
    warn "Ungueltige Eingabe."
  done
  SEL_DEV="${devs[$((pick-1))]}"; SEL_SIZE="${sizes[$((pick-1))]}"

  if (( OFFLINE == 1 )); then
    local bytes; bytes=$(blockdev --getsize64 "$SEL_DEV" 2>/dev/null || echo 0)
    (( bytes == 0 || bytes >= 30000000000 )) \
      || die USB "Fuer den Offline-Installer sind ~32 GB noetig (gewaehlt: $SEL_SIZE)." "Groesseren Stick verwenden oder Online-Modus."
  fi

  local confirm
  printf '\n  %sAlle Daten auf %s (%s) werden geloescht.%s\n' "$RED" "$SEL_DEV" "$SEL_SIZE" "$RST"
  read -r -p "  Zum Bestaetigen 'LOESCHEN' eingeben: " confirm </dev/tty
  [[ "$confirm" == "LOESCHEN" ]] || die Abbruch "Nicht bestaetigt." "Setup erneut starten."
}

# ------------------------------------------------------------------ USB schreiben

fetch() { curl -fL --retry 5 --retry-delay 2 -C - -A "$UA" -o "$2" "$1" || die Download "Download fehlgeschlagen: $1" "Internetverbindung pruefen."; }

prepare_usb() {
  step "USB wird vorbereitet: $SEL_DEV"
  local p1 p2
  if [[ "$SEL_DEV" =~ [0-9]$ ]]; then p1="${SEL_DEV}p1"; p2="${SEL_DEV}p2"; else p1="${SEL_DEV}1"; p2="${SEL_DEV}2"; fi

  umount "${SEL_DEV}"* 2>/dev/null || true
  wipefs -a "$SEL_DEV"        >>"$LOG" 2>&1 || die USB "Datentraeger konnte nicht bereinigt werden." "USB neu einstecken, als root ausfuehren."
  sgdisk --zap-all "$SEL_DEV" >>"$LOG" 2>&1 || true

  if (( OFFLINE == 1 )); then
    command -v mkfs.exfat >/dev/null \
      || die USB "mkfs.exfat fehlt (fuer die Datenpartition)." "exfatprogs installieren, z. B. 'apt install exfatprogs' oder 'dnf install exfatprogs'."
    # p1 = 3 GB FAT32 (EFI + Recovery), p2 = Rest ExFAT (Voll-Installer, >4 GB).
    sgdisk -o -n 1:0:+3G -t 1:0700 -c 1:"MACOS-USB" -n 2:0:0 -t 2:0700 -c 2:"MACOS-DATA" "$SEL_DEV" >>"$LOG" 2>&1 \
      || die USB "Partitionen konnten nicht angelegt werden." "USB neu einstecken."
  else
    sgdisk -o -n 1:0:0 -t 1:0700 -c 1:"MACOS-USB" "$SEL_DEV" >>"$LOG" 2>&1 \
      || die USB "GPT-Partition konnte nicht angelegt werden." "USB neu einstecken."
  fi
  partprobe "$SEL_DEV" >>"$LOG" 2>&1 || true
  command -v udevadm >/dev/null && udevadm settle || true
  sleep 1
  [[ -b "$p1" ]] || die USB "Partition $p1 nicht gefunden." "USB neu verbinden."

  mkfs.vfat -F 32 -n MACOSUSB "$p1" >>"$LOG" 2>&1 \
    || die USB "FAT32-Formatierung fehlgeschlagen." "USB neu einstecken."
  MNT=$(mktemp -d)
  mount "$p1" "$MNT" || die USB "Volume konnte nicht eingehaengt werden." "USB neu verbinden."

  if (( OFFLINE == 1 )); then
    [[ -b "$p2" ]] || die USB "Datenpartition $p2 nicht gefunden." "USB neu verbinden."
    mkfs.exfat -n MACOSDATA "$p2" >>"$LOG" 2>&1 \
      || die USB "ExFAT-Formatierung fehlgeschlagen." "USB neu einstecken."
    DATA_MNT=$(mktemp -d)
    mount "$p2" "$DATA_MNT" || die USB "Datenpartition konnte nicht eingehaengt werden." "USB neu verbinden."
    info "Volume bereit: $MNT (+ Daten $DATA_MNT)"
  else
    info "Volume bereit: $MNT"
  fi
}

assemble_efi() {
  step "EFI und OpenCore werden geschrieben"
  WORK=$(mktemp -d)
  local efi="$WORK/EFI"

  info "OpenCore ${OC_VERSION} wird geladen"
  fetch "https://github.com/acidanthera/OpenCorePkg/releases/download/${OC_VERSION}/OpenCore-${OC_VERSION}-RELEASE.zip" "$WORK/oc.zip"
  unzip -q "$WORK/oc.zip" -d "$WORK/oc"
  mkdir -p "$efi"
  cp -r "$WORK/oc/X64/EFI/BOOT" "$efi/BOOT"
  cp -r "$WORK/oc/X64/EFI/OC"   "$efi/OC"

  local drivers="$efi/OC/Drivers" kexts="$efi/OC/Kexts"
  find "$drivers" -maxdepth 1 -type f ! -name 'OpenRuntime.efi' -delete
  fetch "https://raw.githubusercontent.com/acidanthera/OcBinaryData/master/Drivers/HfsPlus.efi" "$drivers/HfsPlus.efi"
  rm -f "$efi/OC"/*.plist
  mkdir -p "$kexts"

  local k
  # IntelMausi (Intel-Ethernet) immer mit: verlässlicher Weg, den Installer online zu bekommen.
  for k in "Lilu:${LILU_VERSION}" "VirtualSMC:${VSMC_VERSION}" "WhateverGreen:${WEG_VERSION}" "IntelMausi:${INTELMAUSI_VERSION}"; do
    local nm=${k%%:*} ver=${k##*:}
    info "${nm} ${ver} wird geladen"
    fetch "https://github.com/acidanthera/${nm}/releases/download/${ver}/${nm}-${ver}-RELEASE.zip" "$WORK/${nm}.zip"
    unzip -q "$WORK/${nm}.zip" -d "$WORK/${nm}"
    local src; src=$(find "$WORK/${nm}" -maxdepth 3 -type d -name "${nm}.kext" | head -n1)
    [[ -n "$src" ]] || die EFI "Kext ${nm}.kext nicht gefunden." "Erneut versuchen."
    cp -r "$src" "$kexts/${nm}.kext"
  done

  # AirportItlwm (natives Intel-WLAN) fuers installierte System – nur die zur gewaehlten
  # macOS-Version passende Variante laden. Der Kext heißt im Zip immer AirportItlwm.kext,
  # die Version steckt nur im Zip-Namen; als AirportItlwm-<OS>.kext ablegen.
  local sel_darwin os dest
  IFS=: read -r _ _ _ sel_darwin _ _ _ _ <<<"$SELECTED_RELEASE"
  case "$sel_darwin" in
    19) os="Catalina";   dest="Catalina" ;;
    20) os="BigSur";     dest="BigSur" ;;
    21) os="Monterey";   dest="Monterey" ;;
    22) os="Ventura";    dest="Ventura" ;;
    23) os="Sonoma14.4"; dest="Sonoma" ;;
    *)  os=""; dest="" ;;   # High Sierra / Sequoia / Tahoe: kein stabiler AirportItlwm-Build
  esac
  if [[ -n "$os" ]]; then
    info "AirportItlwm ${AIRPORTITLWM_VERSION} (${dest}) wird geladen (WLAN)"
    fetch "https://github.com/OpenIntelWireless/itlwm/releases/download/${AIRPORTITLWM_VERSION}/AirportItlwm_${AIRPORTITLWM_VERSION}_stable_${os}.kext.zip" "$WORK/airport.zip"
    unzip -q "$WORK/airport.zip" -d "$WORK/airport"
    local aw; aw=$(find "$WORK/airport" -maxdepth 3 -type d -name 'AirportItlwm.kext' | head -n1)
    [[ -n "$aw" ]] || die EFI "AirportItlwm.kext (${os}) nicht gefunden." "Erneut versuchen."
    cp -r "$aw" "$kexts/AirportItlwm-${dest}.kext"
  fi

  if [[ "$IS_LAPTOP" -eq 1 ]]; then
    info "VoodooPS2 ${VOODOOPS2_VERSION} wird geladen (Tastatur/Trackpad)"
    fetch "https://github.com/acidanthera/VoodooPS2/releases/download/${VOODOOPS2_VERSION}/VoodooPS2Controller-${VOODOOPS2_VERSION}-RELEASE.zip" "$WORK/VoodooPS2.zip"
    unzip -q "$WORK/VoodooPS2.zip" -d "$WORK/VoodooPS2"
    local vps; vps=$(find "$WORK/VoodooPS2" -maxdepth 3 -type d -name 'VoodooPS2Controller.kext' | head -n1)
    [[ -n "$vps" ]] || die EFI "VoodooPS2Controller.kext nicht gefunden." "Erneut versuchen."
    cp -r "$vps" "$kexts/VoodooPS2Controller.kext"

    info "AppleALC ${ALC_VERSION} wird geladen (Audio: Lautsprecher/Mikro)"
    fetch "https://github.com/acidanthera/AppleALC/releases/download/${ALC_VERSION}/AppleALC-${ALC_VERSION}-RELEASE.zip" "$WORK/AppleALC.zip"
    unzip -q "$WORK/AppleALC.zip" -d "$WORK/AppleALC"
    local alc; alc=$(find "$WORK/AppleALC" -maxdepth 3 -type d -name 'AppleALC.kext' | head -n1)
    [[ -n "$alc" ]] || die EFI "AppleALC.kext nicht gefunden." "Erneut versuchen."
    cp -r "$alc" "$kexts/AppleALC.kext"

    # Batterieanzeige bewusst NICHT ab Werk: SMCBatteryManager + ECEnabler stehen im Verdacht,
    # auf dem Referenz-T480 einen Boot-Haenger (Ladebalken Mitte) auszuloesen. Nachruestbar per
    # scripts/battery.command (mit Backup + dokumentiertem Rettungsweg), bis sauber verifiziert.

    # Intel-Bluetooth ab Werk: IntelBluetoothFirmware + IntelBTPatcher (ein Zip) + BlueToolFixup
    # (aus dem BrcmPatchRAM-Release). Zusammen mit -btlfxallowanyaddr laeuft BT ohne Nacharbeit.
    info "Intel-Bluetooth-Kexte werden geladen (IntelBluetoothFirmware ${IBF_VERSION})"
    fetch "https://github.com/OpenIntelWireless/IntelBluetoothFirmware/releases/download/${IBF_VERSION}/IntelBluetooth-${IBF_VERSION}.zip" "$WORK/IntelBT.zip"
    unzip -q "$WORK/IntelBT.zip" -d "$WORK/IntelBT"
    local ibf ibp
    ibf=$(find "$WORK/IntelBT" -maxdepth 3 -type d -name 'IntelBluetoothFirmware.kext' | head -n1)
    ibp=$(find "$WORK/IntelBT" -maxdepth 3 -type d -name 'IntelBTPatcher.kext' | head -n1)
    [[ -n "$ibf" ]] || die EFI "IntelBluetoothFirmware.kext nicht gefunden." "Erneut versuchen."
    cp -r "$ibf" "$kexts/IntelBluetoothFirmware.kext"
    [[ -n "$ibp" ]] && cp -r "$ibp" "$kexts/IntelBTPatcher.kext"
    info "BlueToolFixup wird geladen (BrcmPatchRAM ${BRCM_VERSION})"
    fetch "https://github.com/acidanthera/BrcmPatchRAM/releases/download/${BRCM_VERSION}/BrcmPatchRAM-${BRCM_VERSION}-RELEASE.zip" "$WORK/Brcm.zip"
    unzip -q "$WORK/Brcm.zip" -d "$WORK/Brcm"
    local btf; btf=$(find "$WORK/Brcm" -maxdepth 3 -type d -name 'BlueToolFixup.kext' | head -n1)
    [[ -n "$btf" ]] || die EFI "BlueToolFixup.kext nicht gefunden." "Erneut versuchen."
    cp -r "$btf" "$kexts/BlueToolFixup.kext"

    info "Laptop-SSDTs werden geladen (EC/USBX, PLUG, PNLF)"
    mkdir -p "$efi/OC/ACPI"
    local ssdt ssdtbase="https://raw.githubusercontent.com/dortania/Getting-Started-With-ACPI/master/extra-files/compiled"
    for ssdt in SSDT-EC-USBX-LAPTOP.aml SSDT-PLUG-DRTNIA.aml SSDT-PNLF.aml; do
      fetch "${ssdtbase}/${ssdt}" "$efi/OC/ACPI/${ssdt}"
    done
  fi

  local amd="$WORK/amd-patches.plist"
  if [[ "$CPU_VENDOR" == "amd" ]]; then
    info "AMD-Vanilla-Kernel-Patches werden geladen"
    fetch "https://raw.githubusercontent.com/AMD-OSX/AMD_Vanilla/master/patches.plist" "$amd"
  else
    amd=""
  fi

  info "config.plist wird fuer die erkannte Hardware erzeugt"
  generate_config "$efi/OC/config.plist" "$amd"

  cp -r "$efi" "$MNT/EFI"
  info "EFI geschrieben"
}

generate_config() {
  local out=$1 amd=$2
  local rec smbios_desktop smbios_laptop smbios sel_darwin
  IFS=: read -r _ _ _ sel_darwin _ _ smbios_desktop smbios_laptop <<<"$SELECTED_RELEASE"
  if [[ "$CPU_VENDOR" == "amd" || "$IS_LAPTOP" -ne 1 ]]; then
    smbios="$smbios_desktop"
  elif [[ "$CPU_VENDOR" == "intel" ]]; then
    # Match a MacBookPro of the same CPU generation for power management.
    case "$CPU_MODEL" in
      78|94)   smbios="MacBookPro13,1" ;;   # Skylake
      142)     smbios="MacBookPro14,1" ;;   # Kaby Lake (e.g. ThinkPad T480)
      158)     smbios="MacBookPro15,2" ;;   # Coffee Lake
      165|166) smbios="MacBookPro16,1" ;;   # Comet Lake
      140|141) smbios="MacBookPro16,2" ;;   # Ice / Tiger Lake
      *)       smbios="$smbios_laptop" ;;
    esac
  else smbios="$smbios_laptop"; fi

  local is_amd=0; [[ "$CPU_VENDOR" == "amd" ]] && is_amd=1
  local igpu_dev=""; [[ "$IS_LAPTOP" -eq 1 && "$CPU_VENDOR" == "intel" ]] && igpu_dev="$INTEL_IGPU_DEV"

  # Gueltige, modellrichtige Seriennummer/MLB fuer iMessage/FaceTime (macserial aus OpenCorePkg).
  local msname gen_serial="" gen_mlb=""
  [[ "$(uname)" == "Darwin" ]] && msname="macserial" || msname="macserial.linux"
  local ms; ms=$(find "$WORK/oc/Utilities/macserial" -maxdepth 1 -type f -name "$msname" 2>/dev/null | head -n1)
  if [[ -n "$ms" ]]; then
    chmod +x "$ms" 2>/dev/null || true
    local pair; pair=$("$ms" -m "$smbios" --num 1 2>/dev/null | grep -m1 '|' || true)
    if [[ -n "$pair" ]]; then
      gen_serial="${pair%%|*}"; gen_serial="${gen_serial// /}"
      gen_mlb="${pair##*|}";   gen_mlb="${gen_mlb// /}"
    fi
  fi
  if [[ -n "$gen_serial" ]]; then info "Gueltige SMBIOS-Seriennummer erzeugt (macserial)"
  else warn "macserial nicht verfuegbar - Platzhalter-Serien (iMessage ggf. nicht moeglich)"; fi

  if ! python3 - "$out" "$smbios" "$is_amd" "$CPU_CORES" "${amd:-}" "$IS_LAPTOP" "$igpu_dev" "$CPU_VENDOR" "$CPU_MODEL" "$sel_darwin" "$gen_serial" "$gen_mlb" <<'PY'
import sys, secrets, plistlib

out, smbios, is_amd, cores, amd = sys.argv[1], sys.argv[2], sys.argv[3] == "1", int(sys.argv[4]), sys.argv[5]
is_laptop = sys.argv[6] == "1"
igpu_dev = int(sys.argv[7], 16) if len(sys.argv) > 7 and sys.argv[7] else None
cpu_intel = len(sys.argv) > 8 and sys.argv[8] == "intel"
cpu_model = int(sys.argv[9]) if len(sys.argv) > 9 and sys.argv[9] else 0
sel_darwin = int(sys.argv[10]) if len(sys.argv) > 10 and sys.argv[10] else 0
gen_serial = sys.argv[11] if len(sys.argv) > 11 and sys.argv[11] else ""
gen_mlb = sys.argv[12] if len(sys.argv) > 12 and sys.argv[12] else ""

# CFG Lock (locked MSR 0xE2) panics macOS early on most stock laptop firmware; patch the
# write out. Haswell+ uses native XCPM, Sandy/Ivy and older the legacy path.
xcpm_cfg_lock = cpu_pm_cfg_lock = False
if cpu_intel:
    if cpu_model in (42, 58) or (0 < cpu_model <= 47):
        cpu_pm_cfg_lock = True
    else:
        xcpm_cfg_lock = True

def kext(bundle, exe):
    return {"Arch": "x86_64", "BundlePath": bundle, "Comment": "", "Enabled": True,
            "ExecutablePath": exe, "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist"}

def driver(path):
    return {"Arguments": "", "Comment": "", "Enabled": True, "LoadEarly": False, "Path": path}

# IntelMausi (Ethernet) immer; AirportItlwm (WLAN) passend zur macOS-Version fuers
# installierte System. Kabel bleibt der sichere Weg fuer die Installation selbst.
net_kexts = [kext("IntelMausi.kext", "Contents/MacOS/IntelMausi")]
_wifi = {19: "Catalina", 20: "BigSur", 21: "Monterey", 22: "Ventura", 23: "Sonoma"}.get(sel_darwin)
if _wifi:
    net_kexts.append(kext("AirportItlwm-%s.kext" % _wifi, "Contents/MacOS/AirportItlwm"))

kernel = {
    "Add": [kext("Lilu.kext", "Contents/MacOS/Lilu"),
            kext("VirtualSMC.kext", "Contents/MacOS/VirtualSMC"),
            kext("WhateverGreen.kext", "Contents/MacOS/WhateverGreen")] + net_kexts,
    "Block": [], "Force": [], "Patch": [],
    "Emulate": {"Cpuid1Data": b"", "Cpuid1Mask": b"", "DummyPowerManagement": False,
                "MaxKernel": "", "MinKernel": ""},
    "Quirks": {"AppleCpuPmCfgLock": cpu_pm_cfg_lock, "AppleXcpmCfgLock": xcpm_cfg_lock, "AppleXcpmExtraMsrs": False,
               "AppleXcpmForceBoost": False, "CustomPciSerialDevice": False, "CustomSMBIOSGuid": False,
               "DisableIoMapper": True, "DisableIoMapperMapping": False, "DisableLinkeditJettison": True,
               "DisableRtcChecksum": False, "ExtendBTFeatureFlags": False, "ExternalDiskIcons": False,
               "ForceAquantiaEthernet": False, "ForceSecureBootScheme": False, "IncreasePciBarSize": False,
               "LapicKernelPanic": False, "LegacyCommpage": False, "PanicNoKextDump": True,
               "PowerTimeoutKernelPanic": True, "ProvideCurrentCpuInfo": is_amd,
               "SetApfsTrimTimeout": -1, "ThirdPartyDrives": False, "XhciPortLimit": False},
    "Scheme": {"CustomKernel": False, "FuzzyMatch": True, "KernelArch": "Auto", "KernelCache": "Auto"},
}

if is_amd and amd:
    with open(amd, "rb") as f:
        patches = plistlib.load(f)
    ak = patches.get("Kernel", {})
    plist_patches = ak.get("Patch", [])
    for p in plist_patches:
        c = p.get("Comment", "")
        r = p.get("Replace")
        if "cpuid_cores_per_package" in c and isinstance(r, (bytes, bytearray)) and len(r) >= 2:
            r = bytearray(r); r[1] = cores & 0xFF; p["Replace"] = bytes(r)
    kernel["Patch"] = plist_patches
    if isinstance(ak.get("Emulate"), dict):
        kernel["Emulate"] = ak["Emulate"]

# --- Laptop extras: PS/2 input, base SSDTs, iGPU framebuffer -------------------
acpi_add = []
if is_laptop:
    kernel["Add"] += [
        kext("VoodooPS2Controller.kext", "Contents/MacOS/VoodooPS2Controller"),
        kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext", "Contents/MacOS/VoodooInput"),
        kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Keyboard.kext", "Contents/MacOS/VoodooPS2Keyboard"),
        kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Trackpad.kext", "Contents/MacOS/VoodooPS2Trackpad"),
        kext("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext", "Contents/MacOS/VoodooPS2Mouse"),
        kext("AppleALC.kext", "Contents/MacOS/AppleALC"),  # Audio (mit alcid-Boot-Arg)
        # Intel-Bluetooth ab Werk (Lilu ist bereits in den Basis-Kexten). BlueToolFixup ist ein
        # Lilu-Plugin und limitiert sich intern auf macOS 12+; -btlfxallowanyaddr ist gesetzt.
        kext("IntelBluetoothFirmware.kext", "Contents/MacOS/IntelBluetoothFirmware"),
        kext("IntelBTPatcher.kext", "Contents/MacOS/IntelBTPatcher"),
        kext("BlueToolFixup.kext", "Contents/MacOS/BlueToolFixup"),
    ]
    acpi_add = [{"Comment": "", "Enabled": True, "Path": p}
                for p in ("SSDT-EC-USBX-LAPTOP.aml", "SSDT-PLUG-DRTNIA.aml", "SSDT-PNLF.aml")]

# USB-Portmap fuer die T480-Familie (UHD 620 / Kaby-Lake-R, iGPU 0x5917): die internen Ports
# (Kamera/Bluetooth/Fingerprint) werden von Lenovo als "nicht anschliessbar" markiert, sodass
# macOS sie ueberspringt. Eine codeless USBMap.kext deklariert sie als Typ 255 (intern) und zwingt
# so die Enumeration - Kamera + BT laufen ab dem ersten Boot, ohne Nacharbeit. Nur fuer dieses
# Layout aktiv; andere Modelle nutzen scripts/usb-fix.command (liest die Ports live aus).
if is_laptop and igpu_dev == 0x5917:
    import os
    _pm = [("HS01", 1, 3), ("HS02", 2, 3), ("HS03", 3, 255), ("HS04", 4, 9), ("HS05", 5, 255),
           ("HS06", 6, 255), ("HS07", 7, 255), ("HS08", 8, 255), ("HS09", 9, 255), ("HS10", 10, 255),
           ("SS01", 13, 3), ("SS02", 14, 3), ("SS04", 16, 9)]
    _pd = lambda n: bytes([n & 0xFF, 0, 0, 0])
    _ports, _top = {}, 0
    for _nm, _num, _ty in _pm:
        _ports[_nm] = {"UsbConnector": _ty, "port": _pd(_num), "usb-port-number": _pd(_num), "usb-port-type": _ty}
        _top = max(_top, _num)
    _usbmap = {
        "CFBundleIdentifier": "com.corpnewt.USBMap", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "USBMap", "CFBundlePackageType": "KEXT", "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1.0", "OSBundleRequired": "Root",
        # macOS baut USB-Ports aus Controller-Registern + SMBIOS-Werks-Map (nicht aus ACPI): die
        # Merge-Kext muss den XHC ueber seine PCI-Adresse (pcidebug 0:20:0 = 00:14.0) treffen und
        # die Werks-Map ueberstimmen (IOProbeScore). IONameMatch/AppleUSBXHCISPTLP binden NICHT.
        "IOKitPersonalities": {smbios + "-XHC": {
            "CFBundleIdentifier": "com.apple.driver.AppleUSBHostMergeProperties",
            "IOClass": "AppleUSBHostMergeProperties", "IOProviderClass": "AppleUSBHostController",
            "IOProbeScore": 5000, "IOParentMatch": {"IOPropertyMatch": {"pcidebug": "0:20:0"}},
            "model": smbios,
            "IOProviderMergeProperties": {"kUSBMuxEnabled": True, "port-count": _pd(_top), "ports": _ports}}},
    }
    _kdir = os.path.join(os.path.dirname(out), "Kexts", "USBMap.kext", "Contents")
    os.makedirs(_kdir, exist_ok=True)
    with open(os.path.join(_kdir, "Info.plist"), "wb") as _f:
        plistlib.dump(_usbmap, _f)
    kernel["Add"].append(kext("USBMap.kext", ""))

def le(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])

def intel_framebuffer(dev):
    # (ig-platform-id, device-id spoof, mem-patch) by GPU PCI device-id. Mirrors the C#
    # IntelIgpuCatalog: exact parts first, then generational ranges. None platform = VESA.
    if dev == 0x5917:            return le(0x87C00000), le(0x00005916), 'stolenfb'  # Kaby Lake-R UHD 620 (T480)
    if 0x3EA0 <= dev <= 0x3EA1:  return le(0x3E9B0000), le(0x00003E9B), 'stolenfb'  # Whiskey Lake UHD 620
    if dev == 0x9B41:            return le(0x3E9B0000), le(0x00003E9B), 'stolenfb'  # Comet Lake-U UHD 620
    if 0x0100 <= dev <= 0x014F:  return None, None, None                            # Sandy Bridge -> VESA
    if 0x0150 <= dev <= 0x016F:  return le(0x01660003), None, None                  # Ivy Bridge HD 4000
    if 0x0400 <= dev <= 0x0D3F:  return le(0x0A260006), le(0x00000412), 'cursor'    # Haswell
    if 0x1600 <= dev <= 0x163F:  return le(0x16260006), le(0x00001626), 'stolenfb'  # Broadwell
    if 0x1900 <= dev <= 0x193F:  return le(0x19160000), None, 'stolenfb'            # Skylake
    if 0x5900 <= dev <= 0x593F:  return le(0x59160000), None, 'stolenfb'            # Kaby Lake
    if 0x3E00 <= dev <= 0x3EFF:  return le(0x3EA50009), le(0x00003EA5), 'stolenfb'  # Coffee Lake
    if 0x9B00 <= dev <= 0x9BFF:  return le(0x3EA50009), le(0x00003EA5), 'stolenfb'  # Comet Lake
    if 0x8A50 <= dev <= 0x8A7F:  return le(0x8A520000), None, 'stolenfb'            # Ice Lake
    return None, None, None

device_props = {}
extra_boot_args = ""
if is_laptop and igpu_dev is not None:
    platform_id, spoof, mem = intel_framebuffer(igpu_dev)
    if platform_id is None:
        extra_boot_args = " -igfxvesa"      # VESA fallback: unaccelerated but shows a picture
    else:
        props = {"AAPL,ig-platform-id": platform_id}
        if spoof is not None:
            props["device-id"] = spoof
        if mem == 'stolenfb':
            props["framebuffer-patch-enable"] = b"\x01\x00\x00\x00"
            props["framebuffer-stolenmem"] = b"\x00\x00\x30\x01"
            props["framebuffer-fbmem"] = b"\x00\x00\x90\x00"
        elif mem == 'cursor':
            props["framebuffer-patch-enable"] = b"\x01\x00\x00\x00"
            props["framebuffer-cursormem"] = b"\x00\x00\x90\x00"
        device_props = {"PciRoot(0x0)/Pci(0x2,0x0)": props}

# Sauberer Boot (Apple-Logo statt Verbose-Text). alcid=<n> aktiviert AppleALC-Audio auf Laptops
# (11 als erster Versuch; ggf. anderen Wert probieren). -btlfxallowanyaddr laesst BlueToolFixup
# das Intel-Bluetooth auch bei NULL-Adresse (Ventura+) akzeptieren. "-v keepsyms=1 debug=0x100"
# hier ergaenzen, um einen Boot-Haenger zu diagnostizieren.
boot_args = (("alcid=11 -btlfxallowanyaddr " if is_laptop else "") + extra_boot_args.strip()).strip()

config = {
    "ACPI": {"Add": acpi_add, "Delete": [], "Patch": [],
             "Quirks": {"FadtEnableReset": False, "NormalizeHeaders": False, "RebaseRegions": False,
                        "ResetHwSig": False, "ResetLogoStatus": True, "SyncTableIds": False}},
    "Booter": {"MmioWhitelist": [], "Patch": [],
               "Quirks": {"AllowRelocationBlock": False, "AvoidRuntimeDefrag": True, "DevirtualiseMmio": False,
                          "DisableSingleUser": False, "DisableVariableWrite": False, "DiscardHibernateMap": False,
                          "EnableSafeModeSlide": True, "EnableWriteUnprotector": is_laptop, "ForceBooterSignature": False,
                          "ForceExitBootServices": False, "ProtectMemoryRegions": False, "ProtectSecureBoot": False,
                          "ProtectUefiServices": False, "ProvideCustomSlide": True, "ProvideMaxSlide": 0,
                          "RebuildAppleMemoryMap": False, "ResizeAppleGpuBars": -1, "SetupVirtualMap": True,
                          "SignalAppleOS": False, "SyncRuntimePermissions": True}},
    "DeviceProperties": {"Add": device_props, "Delete": {}},
    "Kernel": kernel,
    "Misc": {"BlessOverride": [],
             "Boot": {"ConsoleAttributes": 0, "HibernateMode": "None", "HibernateSkipsPicker": False,
                      "HideAuxiliary": False, "InstanceIdentifier": "",
                      "LauncherOption": ("Short" if is_laptop else "Disabled"),
                      "LauncherPath": "Default", "PickerAttributes": 17, "PickerAudioAssist": False,
                      "PickerMode": "Builtin", "PickerVariant": "Auto", "PollAppleHotKeys": True,
                      "ShowPicker": True, "TakeoffDelay": 0, "Timeout": 10},
             "Debug": {"AppleDebug": True, "ApplePanic": True, "DisableWatchDog": True, "DisplayDelay": 0,
                       "DisplayLevel": 2147483650, "LogModules": "*", "SysReport": False, "Target": 65},
             "Entries": [],
             "Security": {"AllowSetDefault": True, "ApECID": 0, "AuthRestart": False, "BlacklistAppleUpdate": True,
                          "DmgLoading": "Signed", "EnablePassword": False, "ExposeSensitiveData": 6,
                          "HaltLevel": 2147483648, "PasswordHash": b"", "PasswordSalt": b"",
                          "ScanPolicy": 0, "SecureBootModel": "Disabled", "Vault": "Optional"},
             "Tools": []},
    "NVRAM": {"Add": {"7C436110-AB2A-4BBB-A880-FE41995C9F82":
                          {"boot-args": boot_args,
                           "csr-active-config": b"\x00\x00\x00\x00",
                           "prev-lang:kbd": b"en-US:0", "run-efi-updater": "No"},
                      "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14":
                          {"DefaultBackgroundColor": b"\x00\x00\x00\x00", "UIScale": b"\x01"}},
              "Delete": {"7C436110-AB2A-4BBB-A880-FE41995C9F82": ["boot-args", "csr-active-config"],
                         "4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14": ["DefaultBackgroundColor", "UIScale"]},
              "LegacySchema": {}, "WriteFlash": True},
    "PlatformInfo": {"Automatic": True, "CustomMemory": False,
                     "Generic": {"AdviseFeatures": False,
                                 "MLB": gen_mlb or secrets.token_hex(8).upper()[:17].ljust(17, "0"),
                                 "MaxBIOSVersion": False, "ProcessorType": 0, "ROM": secrets.token_bytes(6),
                                 "SpoofVendor": True, "SystemMemoryStatus": "Auto", "SystemProductName": smbios,
                                 "SystemSerialNumber": gen_serial or secrets.token_hex(6).upper(),
                                 "SystemUUID": str(__import__("uuid").uuid4()).upper()},
                     "UpdateDataHub": True, "UpdateNVRAM": True, "UpdateSMBIOS": True,
                     "UpdateSMBIOSMode": "Create", "UseRawUuidEncoding": False},
    "UEFI": {"APFS": {"EnableJumpstart": True, "GlobalConnect": False, "HideVerbose": False,
                      "JumpstartHotPlug": False, "MinDate": -1, "MinVersion": -1},
             "AppleInput": {"AppleEvent": "Builtin", "CustomDelays": False, "GraphicsInputMirroring": True,
                            "KeyInitialDelay": 50, "KeySubsequentDelay": 5, "PointerPollMask": -1,
                            "PointerPollMax": 0, "PointerPollMin": 0, "PointerSpeedDiv": 1, "PointerSpeedMul": 1},
             "Audio": {"AudioSupport": False},
             "ConnectDrivers": True,
             "Drivers": [driver("OpenRuntime.efi"), driver("HfsPlus.efi")],
             "Input": {"KeyFiltering": False, "KeyForgetThreshold": 5, "KeySupport": True,
                       "KeySupportMode": "Auto", "PointerSupport": False, "PointerSupportMode": "ASUS",
                       "TimerResolution": 50000},
             "Output": {"ClearScreenOnModeSwitch": False, "ConsoleMode": "", "DirectGopRendering": False,
                        "ForceResolution": False, "GopPassThrough": "Disabled", "IgnoreTextInGraphics": False,
                        "InitialMode": "Auto", "ProvideConsoleGop": True, "ReconnectGraphicsOnConnect": False,
                        "ReconnectOnResChange": False, "ReplaceTabWithSpace": False, "Resolution": "Max",
                        "SanitiseClearScreen": False, "TextRenderer": "BuiltinGraphics", "UIScale": 0,
                        "UgaPassThrough": False},
             "ProtocolOverrides": {k: False for k in
                 ["AppleAudio", "AppleBootPolicy", "AppleDebugLog", "AppleEg2Info", "AppleFramebufferInfo",
                  "AppleImageConversion", "AppleImg4Verification", "AppleKeyMap", "AppleRtcRam", "AppleSecureBoot",
                  "AppleSmcIo", "AppleUserInterfaceTheme", "DataHub", "DeviceProperties", "FirmwareVolume",
                  "HashServices", "OSInfo", "UnicodeCollation"]},
             "Quirks": {"ActivateHpetSupport": False, "DisableSecurityPolicy": False, "EnableVectorAcceleration": True,
                        "EnableVmx": False, "ExitBootServicesDelay": 0, "ForceOcWriteFlash": False,
                        "ForgeUefiSupport": False, "IgnoreInvalidFlexRatio": False, "ReleaseUsbOwnership": True,
                        "ReloadOptionRoms": False, "RequestBootVarRouting": True, "ResizeGpuBars": -1,
                        "ResizeUsePciRbIo": False, "ShimRetainProtocol": False, "TscSyncTimeout": 0,
                        "UnblockFsConnect": False},
             "ReservedMemory": []},
}

with open(out, "wb") as f:
    plistlib.dump(config, f)
PY
  then :; else
    die EFI "config.plist konnte nicht erzeugt werden." "python3 pruefen."
  fi
}

# --------------------------------------------------------------- Recovery-Download

rand_hex() { openssl rand -hex "$1" | tr 'a-f' 'A-F'; }

download_recovery() {
  local board ostype name
  IFS=: read -r name _ _ _ board ostype _ _ <<<"$SELECTED_RELEASE"
  step "macOS ${name} wird von Apple geladen"

  local hdr; hdr=$(mktemp)
  curl -s -D "$hdr" -o /dev/null -H "Host: osrecovery.apple.com" -H "Connection: close" -A "$UA" "$OSRECOVERY/" \
    || die Recovery "Verbindung zum Apple-Wiederherstellungsdienst fehlgeschlagen." "Internetverbindung pruefen."
  local session; session=$(grep -oiE 'session=[^;[:space:]]+' "$hdr" | head -n1); rm -f "$hdr"
  [[ -n "$session" ]] || die Recovery "Kein Sitzungscookie erhalten." "Internetverbindung pruefen und erneut versuchen."

  local body resp
  body=$(printf 'cid=%s\nsn=%s\nbid=%s\nk=%s\nfg=%s\nos=%s' \
    "$(rand_hex 8)" "$MLB_ZERO" "$board" "$(rand_hex 32)" "$(rand_hex 32)" "$ostype")
  resp=$(curl -s -X POST --data-binary "$body" \
    -H "Host: osrecovery.apple.com" -H "Connection: close" -A "$UA" \
    -H "Cookie: $session" -H "Content-Type: text/plain" \
    "$OSRECOVERY/InstallationPayload/RecoveryImage") \
    || die Recovery "Recovery-Anfrage fehlgeschlagen." "Internetverbindung pruefen."

  local AU AT CU CT
  AU=$(awk -F': ' '/^AU: /{print $2}' <<<"$resp")
  AT=$(awk -F': ' '/^AT: /{print $2}' <<<"$resp")
  CU=$(awk -F': ' '/^CU: /{print $2}' <<<"$resp")
  CT=$(awk -F': ' '/^CT: /{print $2}' <<<"$resp")
  [[ -n "$AU" && -n "$AT" && -n "$CU" && -n "$CT" ]] \
    || die Recovery "Antwort des Apple-Dienstes unvollstaendig." "macOS-Auswahl und Verbindung pruefen."

  local dir="$MNT/com.apple.recovery.boot"; mkdir -p "$dir"
  info "BaseSystem.dmg wird geladen (mehrere GB)"
  curl -L --retry 5 --retry-delay 2 -C - -A "$UA" -H "Cookie: AssetToken=$AT" -o "$dir/BaseSystem.dmg" "$AU" \
    || die Recovery "Download von BaseSystem.dmg fehlgeschlagen." "Internetverbindung pruefen, Setup erneut ausfuehren."
  info "BaseSystem.chunklist wird geladen"
  curl -L --retry 5 --retry-delay 2 -A "$UA" -H "Cookie: AssetToken=$CT" -o "$dir/BaseSystem.chunklist" "$CU" \
    || die Recovery "Download der Chunklist fehlgeschlagen." "Internetverbindung pruefen."

  step "Recovery-Abbildung wird geprueft"
  if ! python3 - "$dir/BaseSystem.dmg" "$dir/BaseSystem.chunklist" <<'PY'
import sys, struct, hashlib
img, ck = sys.argv[1], sys.argv[2]
d = open(ck, "rb").read()
if len(d) < 36: sys.exit("chunklist zu kurz")
magic, hsize, fv, cm, sm, cnt, coff, soff = struct.unpack_from("<4sIBBBxQQQ", d, 0)
if magic != b"CNKL": sys.exit("ungueltige chunklist")
with open(img, "rb") as f:
    off = coff
    for i in range(cnt):
        size, h = struct.unpack_from("<I32s", d, off); off += 36
        sha = hashlib.sha256(); rem = size
        while rem:
            b = f.read(min(rem, 1 << 20))
            if not b: sys.exit("image zu kurz")
            sha.update(b); rem -= len(b)
        if sha.digest() != h: sys.exit("chunk %d ungueltig" % i)
PY
  then :; else
    die Pruefung "Pruefsumme der Recovery-Abbildung stimmt nicht." "Download beschaedigt - Setup erneut ausfuehren."
  fi
  info "Recovery verifiziert"
}

# ------------------------------------------------------------------------ Abschluss

# Der eine Nachlauf-Helfer (start-me.command) + das Tastaturlayout kommen mit auf den Stick,
# damit der Nutzer nach dem ersten macOS-Start nur doppelklicken muss (Layout dann lokal).
write_startme() {
  local rawbase="https://raw.githubusercontent.com/florianthepro/macos/main"
  curl -fsSL "$rawbase/scripts/start-me.command" -o "$MNT/start-me.command" 2>/dev/null \
    || warn "start-me.command konnte nicht geladen werden."
  curl -fsSL "$rawbase/assets/keyboard/Windows-German.keylayout" -o "$MNT/Windows-German.keylayout" 2>/dev/null \
    || warn "Windows-German.keylayout konnte nicht geladen werden."
  if [[ -n "$DATA_MNT" && -d "$DATA_MNT" ]]; then
    cp "$MNT/start-me.command" "$DATA_MNT/start-me.command" 2>/dev/null || true
    cp "$MNT/Windows-German.keylayout" "$DATA_MNT/Windows-German.keylayout" 2>/dev/null || true
  fi
  info "start-me.command auf den Stick gelegt (nach der Installation doppelklicken)"
}

finish() {
  local name; IFS=: read -r name _ <<<"$SELECTED_RELEASE"
  sync
  step "Fertig - der USB-Stick ist bootfaehig."
  cat <<EOF

  ${GRN}macOS ${name} wurde auf ${SEL_DEV} geschrieben.${RST}

  1.  Rechner neu starten.
  2.  Boot-Menue oeffnen (je nach Board F12, F11, F8 oder Esc).
  3.  Den USB-Datentraeger im UEFI-Modus auswaehlen.
  4.  Im OpenCore-Menue "macOS Base System" starten.
  5.  Festplattendienstprogramm oeffnen und das Ziellaufwerk als APFS loeschen.
$(if (( OFFLINE == 1 )); then cat <<OFF
  6.  Dienstprogramme -> Terminal, EIN Kommando:
        bash "/Volumes/MACOS-DATA/offline-install.command"
      (formatiert automatisch + installiert, keine Rueckfragen)
  7.  Nach dem Neustart im Boot-Menue "macOS Installer" waehlen (NICHT
      "Base System"), bis der Willkommensassistent erscheint.
  8.  KEIN Internet noetig - der komplette Installer liegt auf dem Stick.
      Details/Alternativen stehen in INSTALL.txt auf der Datenpartition.
OFF
else cat <<ON
  6.  "macOS installieren" waehlen und dem Assistenten folgen.
  7.  macOS wird dabei von Apple geladen - Internetverbindung erforderlich.
ON
fi)

  Protokoll: ${LOG}
EOF
}

download_installer() {
  (( OFFLINE == 1 )) || return 0
  step "Voll-Installer wird geladen (Offline)"
  local name marketing; IFS=: read -r name marketing _ _ _ _ _ _ <<<"$SELECTED_RELEASE"
  local major="${marketing%%.*}"
  info "Apple-Softwarekatalog wird gelesen"
  local catalog="https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
  curl -fsSL "$catalog" -o "$WORK/catalog.plist" \
    || die Recovery "Apple-Katalog konnte nicht geladen werden." "Internet pruefen, erneut ausfuehren."
  local url
  url=$(python3 - "$major" "$WORK/catalog.plist" <<'PY'
import sys, plistlib, urllib.request, re
target, path = sys.argv[1], sys.argv[2]
data = plistlib.load(open(path, "rb"))
best = None
for pid, p in data.get("Products", {}).items():
    ia = next((k["URL"] for k in p.get("Packages", []) if k.get("URL", "").endswith("InstallAssistant.pkg")), None)
    if not ia:
        continue
    dist = (p.get("Distributions") or {}).get("English")
    ver = ""
    if dist:
        try:
            x = urllib.request.urlopen(dist, timeout=30).read().decode("utf-8", "ignore")
            m = re.search(r'id="InstallAssistantAuto"[^>]*versStr="([^"]+)"', x)
            if m:
                ver = m.group(1)
        except Exception:
            pass
    if not ver or ver.split(".")[0] != target:
        continue
    d = p.get("PostDate")
    if best is None or (d and d > best[0]):
        best = (d, ia)
if not best:
    sys.exit(1)
print(best[1])
PY
) || die Recovery "Kein Offline-Installer fuer diese Version im Apple-Katalog gefunden." "Andere Version waehlen."
  info "InstallAssistant.pkg wird geladen (~12 GB, dauert lange)"
  curl -L --retry 5 --retry-delay 2 -C - -o "$DATA_MNT/InstallAssistant.pkg" "$url" \
    || die Recovery "Download des Voll-Installers fehlgeschlagen." "Erneut ausfuehren, der Download wird fortgesetzt."
  info "Installer-Skript + Anleitung werden abgelegt"
  # Primaer: unser Ein-Kommando-Skript (formatiert automatisch, keine Rueckfragen).
  curl -fsSL "https://raw.githubusercontent.com/florianthepro/macos/main/scripts/offline-install.command" \
    -o "$DATA_MNT/offline-install.command" || warn "offline-install.command konnte nicht geladen werden."
  # Fallback: CorpNewt UnPlugged (interaktiv).
  curl -fsSL "https://raw.githubusercontent.com/corpnewt/UnPlugged/main/UnPlugged.command" \
    -o "$DATA_MNT/UnPlugged.command" || warn "UnPlugged.command konnte nicht geladen werden."
  cat > "$DATA_MNT/INSTALL.txt" <<EOF
Offline-Installation von macOS $name
==============================================================

Dieser Stick enthaelt den KOMPLETTEN Installer - es wird KEIN Internet benoetigt.

1. Stick booten, im OpenCore-Menue "macOS Base System" waehlen.
2. Dienstprogramme -> Terminal. EIN Kommando:

     bash "/Volumes/MACOS-DATA/offline-install.command"

   Das Skript formatiert die interne Platte automatisch und installiert -
   keine manuelle Formatierung, keine Rueckfragen (10 s Countdown, Abbruch Strg-C).
   Terminal-Fenster offen lassen.

   Mehrere interne Platten? Mit Ziel starten, z. B.:
     bash "/Volumes/MACOS-DATA/offline-install.command" /dev/disk0

3. Der Rechner startet danach neu. WICHTIG: Erscheint wieder das Boot-Menue,
   den NEUEN Eintrag "macOS Installer" waehlen - NICHT "macOS Base System"!
   Bei jedem weiteren Neustart wiederholen ("macOS Installer", spaeter
   "Macintosh HD"), bis der Willkommensassistent erscheint.

Nur bei Sonoma/Sequoia, falls "MACOS-DATA" fehlt:
     diskutil list physical
     mkdir "/Volumes/MACOS-DATA"
     /sbin/mount_exfat /dev/diskXsY "/Volumes/MACOS-DATA"

Alternative (interaktiv): bash "/Volumes/MACOS-DATA/UnPlugged.command"
EOF
}

main() {
  require_root "$@"
  require_tools
  scan_hardware
  choose_version
  choose_mode
  choose_usb
  prepare_usb
  assemble_efi
  download_recovery
  download_installer
  write_startme
  finish
}

main "$@"

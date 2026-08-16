# VCE – Virtual Compatible EFI

**Vision:** Eine EFI‑Umgebung, die Hardware so weit abstrahiert/virtualisiert,
dass **jedes Betriebssystem** darauf sauber läuft – und die sich ihre
Installationsquellen **von deinem eigenen Server** holt: beim Booten Menüpunkt
wählen → Windows, Linux, BSD … installieren.

**VCE ist eigenständig und skalierbar:** dieses Verzeichnis hat keinerlei
Abhängigkeit zum restlichen Repository und kann jederzeit unverändert in ein
eigenes Repo umziehen. Der **macOS‑Teil bleibt bewusst außerhalb** – VCE
referenziert ihn nur als Menü‑Hinweis (Apple lässt keine Netzinstallation von
Fremdservern zu; dafür ist der OpenCore‑Stick des macOS‑Projekts zuständig).

## Die drei Bausteine (alle getestet)

| Skript | Was es tut |
| --- | --- |
| **`build-vce.sh`** | Baut den **VCE‑Boot‑Stick**: lädt offizielles iPXE (`x86_64-efi`), schreibt `EFI/BOOT/BOOTX64.EFI` + `autoexec.ipxe`, die per DHCP online geht und das Menü von deinem Server lädt. |
| **`setup-server.sh`** | Richtet die **Serverseite mit einem Befehl** ein: erzeugt `vce/` im Webroot mit fertigem `menu.ipxe` (deine URL eingesetzt), lädt `wimboot`, optional den Debian‑Netzinstaller, legt die ISO‑Ablageordner an und schreibt eine nginx‑Beispielkonfiguration. Was noch von Hand zu befüllen ist, steht danach in `BEFUELLEN.txt`. |
| **`add-to-opencore.sh`** | Hängt VCE als **Tool in einen OpenCore‑Picker** (z. B. den macOS‑Stick): kopiert `ipxe.efi` nach `EFI/OC/Tools/` und registriert es in der `config.plist` (Backup + Validierung, idempotent). Danach ist „VCE Netz‑Installation" ein Menüpunkt im normalen Boot‑Menü. |

## Schnellstart

```bash
# 1) Serverseite (auf dem Server, einmalig)
sudo ./setup-server.sh --url http://mein-server.example --root /srv/www --with-debian
#    danach: ISOs nach BEFUELLEN.txt ablegen, nginx mit vce-nginx.conf.example starten

# 2a) Eigener VCE-Stick ...
./build-vce.sh --server http://mein-server.example --out /pfad/zum/stick
#     -> Ordner EFI auf einen FAT32-Stick, davon booten -> Menue erscheint

# 2b) ... oder als Menuepunkt in einem OpenCore-Stick
./add-to-opencore.sh /Volumes/EFI/EFI
```

```
VCE-Stick / OpenCore-Tool                Dein Server (setup-server.sh)
┌──────────────────────────┐   HTTP   ┌────────────────────────────────┐
│ iPXE (BOOTX64.EFI/Tool)  │ ───────► │ /vce/menu.ipxe   (das Menü)    │
│ autoexec.ipxe            │          │ /vce/wimboot     (Win-Kette)   │
│  → chain SERVER/menu.ipxe│          │ /vce/…/isos      (die Images)  │
└──────────────────────────┘          └────────────────────────────────┘
```

## Architektur‑Stufen (ehrlich getrennt)

| Stufe | Was | Status |
| --- | --- | --- |
| **1 – Universal‑Boot + Netz‑Installer** | Bootmenü (iPXE) vom eigenen Server; Windows (wimboot), Linux (Kernel/initrd), BSD (sanboot) laufen **nativ** – Kompatibilität über den jeweils richtigen Boot‑Pfad, nicht über Emulation. | ✅ **fertig (dieses Verzeichnis)** |
| **2 – Kompatibilitäts‑Shims pro OS** | Verallgemeinerung des OpenCore‑Prinzips: pro OS ein Profil (ACPI‑Overlays, Geräte‑Injektion, Firmware‑Variablen), das die reale Hardware passend präsentiert. | 🔬 geplant |
| **3 – Firmware‑Virtualisierung** | Schlanker Typ‑1‑Hypervisor unter dem OS mit virtueller Standard‑Hardware (virtio‑NIC, AHCI, Standard‑Framebuffer), sodass *unmodifizierte* OS‑Images überall laufen. Eigenes Hypervisor‑Projekt (Größenordnung Jahre). | 🧭 Fernziel |

Stufe 1 liefert das Nutzererlebnis der Vision bereits vollständig für
Windows/Linux/BSD; die Stufen 2/3 machen daraus schrittweise „läuft überall,
unmodifiziert".

## Grenzen (keine falschen Erwartungen)

- **macOS** ist per Design ausgenommen (Apple‑Signaturkette) – der Menüpunkt
  verweist auf den OpenCore‑Stick des macOS‑Projekts.
- **Windows** braucht die entpackte ISO + `wimboot` auf dem Server
  (macht `setup-server.sh` bzw. `BEFUELLEN.txt` klar).
- Stufe 1 **virtualisiert keine Hardware** – sie bootet native Installer über
  das Netz. Genau deshalb ist sie heute schon stabil.

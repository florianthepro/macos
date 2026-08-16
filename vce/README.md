# VCE – Virtual Compatible EFI

**Vision:** Eine EFI‑Umgebung, die die Hardware so weit abstrahiert/virtualisiert,
dass **jedes Betriebssystem** darauf sauber läuft – und die sich ihre
Installationsquellen (ISOs/Installer) **von deinem eigenen Server** holt: beim
Booten eine Taste drücken → Menü → Windows, macOS, Linux, BSD … auswählen und
installieren.

## Architektur (3 Stufen – ehrlich getrennt)

| Stufe | Was | Status |
| --- | --- | --- |
| **1 – Universal‑Boot + Netz‑Installer** | Bootmenü in der EFI (iPXE): holt das Menü + die Installer **von deinem Server** (HTTP). Windows (wimboot), Linux (Kernel/initrd), BSD (Loader/memdisk) laufen nativ – „kompatibel" wird per OS‑spezifischem Boot‑Pfad gelöst, nicht per Emulation. macOS kommt über den OpenCore‑Stick dieses Repos (Netz‑Install von macOS ist Apple‑seitig gesperrt). | ✅ **dieses Verzeichnis** |
| **2 – Kompatibilitäts‑Shims pro OS** | Was OpenCore für macOS ist (ACPI‑Patches, Geräte‑Injektion, SMBIOS), verallgemeinert: pro OS ein Profil, das die reale Hardware passend „erzählt" (DSDT‑Overlays, Geräte‑IDs, Firmware‑Variablen). | 🔬 geplant |
| **3 – Echte Virtualisierung in der Firmware** | Ein schlanker Typ‑1‑Hypervisor unter dem OS, der virtuelle Standard‑Hardware anbietet (virtio/emulierte NICs, AHCI, Standard‑GPU‑Framebuffer), sodass *unmodifizierte* OS‑Images überall laufen. Technisch = eigenes Hypervisor‑Projekt (Größenordnung Jahre). | 🧭 Fernziel |

Stufe 1 liefert bereits das Nutzererlebnis der Vision: **Taste drücken → Menü vom
eigenen Server → OS installieren** – für alles außer macOS ohne weitere Tricks,
und macOS deckt der Haupt‑Installer dieses Repos ab.

## Wie es funktioniert (Stufe 1)

```
USB/EFI (build-vce.sh)                    Dein Server (vce/server/)
┌──────────────────────────┐   HTTP   ┌────────────────────────────────┐
│ EFI/BOOT/BOOTX64.EFI     │ ───────► │ /vce/menu.ipxe   (das Menü)    │
│  = iPXE                  │          │ /vce/isos/…      (die Images)  │
│ autoexec.ipxe            │          │ /vce/wimboot     (Win-Loader)  │
│  → chain SERVER/menu.ipxe│          └────────────────────────────────┘
└──────────────────────────┘
```

- **`build-vce.sh`** baut den VCE‑EFI‑Ordner: lädt iPXE (offizielles
  `x86_64-efi/ipxe.efi`) und schreibt eine `autoexec.ipxe`, die per DHCP online
  geht und das Menü von **deinem Server** lädt (URL beim Bauen angeben).
- **`server/`** enthält die Vorlagen für die Server‑Seite: `menu.ipxe.example`
  (das Bootmenü) und ein README mit Ordnerlayout + nginx‑Beispiel.
- **„Bestimmte Taste drücken":** VCE bootet entweder als eigener Stick, oder du
  legst `ipxe.efi` als **Tool in den OpenCore‑Picker** des macOS‑Sticks
  (`EFI/OC/Tools/ipxe.efi` + Eintrag unter `Misc → Tools`), dann ist VCE ein
  Menüpunkt im normalen Boot‑Menü.

## Schnellstart

```bash
# 1) VCE-EFI bauen (Server-URL = dein Server)
./build-vce.sh --server http://mein-server.example --out /pfad/zum/stick

# 2) Server befuellen (einmalig)
#    vce/server/README.md folgen: menu.ipxe anpassen, ISOs ablegen, nginx starten

# 3) Stick booten -> VCE-Menue erscheint -> OS waehlen -> installieren
```

## Grenzen (damit keine falschen Erwartungen entstehen)

- **macOS** lässt sich nicht legal/technisch per iPXE vom eigenen Server
  installieren (Apple‑Signaturkette) – dafür bleibt der OpenCore‑Stick des
  Hauptprojekts zuständig; VCE verweist im Menü darauf.
- **Windows** braucht auf dem Server neben der ISO die `wimboot`‑Kette (im
  Server‑README beschrieben).
- Stufe 1 virtualisiert **keine** Hardware – sie bootet native Installer. Die
  Virtualisierung ist Stufe 2/3 (siehe Tabelle), damit VCE von Anfang an ehrlich
  bleibt.

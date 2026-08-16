# VCE-Host – die Virtualisierungsschicht (Stufe 2)

Hier passiert genau das, was VCE ausmacht: **VCE spricht mit der echten
Hardware – das Betriebssystem sieht nur virtuelle Hardware.**

```
┌─────────────────────────── Gast-OS (Windows/Linux/BSD) ───────────────────────────┐
│  sieht: virtuelle Platte (virtio) · virtuelles EFI (OVMF) · virtuelle NIC · VGA   │
│  legt seinen Bootloader im VIRTUELLEN EFI ab  ->  landet UNTER dem echten         │
└──────────────────────────────────▲────────────────────────────────────────────────┘
                                   │ emulierte Standard-Hardware (KVM/QEMU)
┌──────────────────────────────────┴────────────────────────────────────────────────┐
│  VCE-Host (minimales Debian + KVM): spricht mit der ECHTEN Hardware               │
│  /var/lib/vce/disks/<vm>.qcow2   <- die "Festplatte" des Gastes (nur eine Datei)  │
│  /var/lib/vce/nvram/<vm>.fd      <- das "EFI-NVRAM" des Gastes (pro VM eigene     │
│                                      Kopie - Bootloader-Eintraege bleiben hier)   │
│  echte EFI-Partition + Bootkette  -> gehoert weiter VCE, kein Gast fasst sie an   │
└───────────────────────────────────────────────────────────────────────────────────┘
```

**Warum das die Anforderung exakt erfüllt:**
- Der Gast bekommt eine **virtuelle Festplatte** (qcow2-Datei). Formatieren,
  Partitionieren, Bootloader schreiben – alles passiert **in der Datei**, nie auf
  der echten Platte.
- Der Gast bekommt ein **virtuelles EFI** (OVMF) mit **eigener NVRAM-Kopie pro
  VM**. Legt Windows/Linux dort Boot-Einträge ab, liegen die *unter* dem echten
  EFI – das echte bootet weiterhin nur VCE.
- Der VCE-Host nutzt Linux-Treiber + KVM: **maximale echte
  Hardware-Kompatibilität nach unten**, stabile Standard-Hardware nach oben
  (virtio-Disk/NIC, Q35-Chipsatz, VGA) – dadurch läuft jedes Gast-OS mit
  Bordmitteln.

## Installation – zwei Wege

**A. Vollautomatisch über das VCE-Bootmenü** (empfohlen):
`setup-server.sh` legt den Menüpunkt **„VCE-Host installieren"** an. Er startet
den Debian-Netzinstaller mit Preseed: Platte automatisch partitionieren, Basis
installieren, VCE-Host-Provisionierung ausführen – ohne eine einzige Frage.
Nach dem Neustart bootet die Maschine direkt ins **VCE-Menü**.

**B. Auf ein vorhandenes Debian 12/13:**
```bash
sudo ./provision-host.sh http://mein-server.example
```

## Das VCE-Menü (auf dem Host, Konsole 1)

- **Neue VM**: Name, Größe, ISO wählen (lokal oder vom Server laden) → qcow2 +
  eigene OVMF-NVRAM-Kopie werden angelegt, VM bootet die ISO im virtuellen EFI.
- **VM starten / Liste / Löschen**, **ISO vom Server laden**, **Shell**, **Ausschalten**.
- Dateien: Disks `/var/lib/vce/disks/`, ISOs `/var/lib/vce/isos/`,
  EFI-NVRAM `/var/lib/vce/nvram/`.

## Effizienz & Unsichtbarkeit (die VCE-Ziele)

**VCE soll für den Nutzer unsichtbar sein und fast nichts kosten.** Dazu:

- **Kiosk-Modus:** im Menü einmal „Standard-VM festlegen" – ab dann bootet das
  Gerät **direkt in das OS** (Vollbild), ohne dass der Nutzer VCE je sieht.
  Erst wenn das OS heruntergefahren wird, erscheint das VCE-Menü.
- **CPU kostet (fast) nichts:** KVM emuliert keine CPU – Gast-Code läuft
  **nativ** auf dem Prozessor (VT-x/AMD-V). Die Schicht arbeitet nur bei
  Ein-/Ausgabe; virtio (Platte/Netz) ist nahe nativ.
- **RAM-Fußabdruck:** Debian-minimal-Host heute ~300–500 MB. Ziel-Profil
  (Roadmap): Alpine/Buildroot-Host nur mit Kernel + KVM + Menü → **~100–150 MB**.
- **Passthrough (Roadmap):** GPU/NVMe per VFIO **direkt** an die Standard-VM →
  null Übersetzungskosten für die schweren Geräte. (Bewusster Tausch: dieses
  eine Gerät braucht dann wieder echte Gast-Treiber.)
- Bewusst **kein** eigener Mikro-Hypervisor mit eigenen Treibern (à la ESXi):
  minimal kleiner, aber er würde das Treiber-Universum kosten – VCE liefe dann
  nur noch auf einer Kompatibilitätsliste statt auf jeder Hardware.

## Ehrliche Grenzen

- Braucht **VT-x/AMD-V** (bei praktisch jedem Gerät seit ~2010 vorhanden; im
  BIOS aktivieren). CPU-Leistung im Gast ist nahezu nativ (KVM), Grafik ist
  emuliert (Desktop ok, Spiele nein – GPU-Passthrough ist ein späterer Ausbau).
- **macOS als Gast** ist ausgenommen (Apple-EULA bindet macOS an Apple-Hardware);
  dafür bleibt der OpenCore-Stick des macOS-Projekts zuständig.
- Stufe 3 (dasselbe direkt in der Firmware statt über eine Linux-Schicht)
  bleibt Forschungs-Fernziel; der VCE-Host liefert das Verhalten schon heute.

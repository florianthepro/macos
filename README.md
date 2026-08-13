# macOS USB Setup

Windows-Programm (`setup.exe`), das einen bootfähigen macOS-Installations-Stick
erstellt. Es erkennt die Hardware, zeigt die darauf lauffähigen macOS-Versionen
als Kacheln, lädt die gewählte Version direkt von Apple und schreibt einen
OpenCore-USB-Stick, der auf die Hardware zugeschnitten ist.

Die Logik der beiden bekannten Referenzprojekte (Hardware-/EFI-Erkennung sowie
macOS-Download) ist eigenständig neu implementiert – es wird kein Fremdprogramm
heruntergeladen oder aufgerufen. Extern sind nur die Daten selbst: die
macOS-Recovery-Abbildungen von Apple sowie die OpenCore-/Kext-Binärdateien
(„EFIs"), die beim Bauen fest eingebunden werden.

## Ablauf

1. Start → Ladebalken während des Hardware-Scans
2. Kacheln aller lauffähigen macOS-Versionen (empfohlen / experimentell, mit Hinweisen)
3. Auswahl der Version
4. Auswahl des USB-Datenträgers (wird vollständig gelöscht)
5. Vorbereiten → EFI schreiben → macOS laden → prüfen
6. Neustart und vom USB booten

## Voraussetzungen

- Windows 10/11 x64
- .NET SDK 8 (nur zum Bauen)
- PowerShell 5.1+ (für `build.ps1`)
- Administratorrechte zur Laufzeit (Partitionieren/Formatieren)
- Internetverbindung beim ersten Lauf (Apple-Recovery-Download)

## Bauen

```powershell
./build.ps1
```

`build.ps1` lädt die offiziellen OpenCore-, Lilu-, VirtualSMC- und
WhateverGreen-Releases sowie `HfsPlus.efi` und die AMD-Vanilla-Kernel-Patches,
packt daraus `efi-payload.zip` (wird in die exe eingebettet) und veröffentlicht
anschließend eine eigenständige `publish/setup.exe`.

Optionen:

- `./build.ps1 -PayloadOnly` – nur die eingebettete EFI-Nutzlast neu bauen
- `./build.ps1 -SkipPayload` – mit vorhandener Nutzlast veröffentlichen

## Aufbau

| Bereich | Inhalt |
| --- | --- |
| `Core/Hardware` | WMI-Hardware-Scan (CPU, GPU, Firmware, RAM) |
| `Core/Compatibility` | macOS-Kompatibilitätsmatrix je CPU/GPU |
| `Core/Recovery`, `Core/Download` | Apple-Recovery-Abruf (macrecovery-Port) + Chunklist-Prüfung |
| `Core/Usb` | USB-Erkennung und FAT32-Vorbereitung (diskpart) |
| `Core/Efi` | OpenCore-EFI + hardware-spezifische `config.plist` |
| `Core/Setup` | Ablaufsteuerung mit Fortschritt |
| `App` | WPF-Oberfläche (MVVM-Assistent) |

## Erzeugter USB-Stick

- Eine FAT32-Partition (GPT), UEFI-bootfähig
- `EFI/` mit OpenCore, `OpenRuntime.efi`, `HfsPlus.efi` und den Basis-Kexts
- `EFI/OC/config.plist`, erzeugt für die erkannte Hardware
- `com.apple.recovery.boot/` mit `BaseSystem.dmg` + `BaseSystem.chunklist`

Vom Stick booten (UEFI), im OpenCore-Menü „macOS Base System" wählen, im
Festplattendienstprogramm das Ziel als APFS löschen und macOS installieren.

## Hinweise

- Seriennummer/MLB in der `config.plist` sind Platzhalter. Zum Booten und
  Installieren genügt das; für iMessage/FaceTime müssen später gültige Werte
  gesetzt werden.
- AMD-Ryzen wird über die AMD-Vanilla-Kernel-Patches unterstützt (automatisch
  auf die Kernanzahl gesetzt).
- Wird der Stick im Boot-Menü nicht angezeigt: im Firmware-Setup CSM
  deaktivieren bzw. „UEFI USB" aktivieren.
- Läuft ein Schritt auf einen Fehler, zeigt die Oberfläche eine fachliche
  Meldung samt Empfehlung. Vollständiges Protokoll:
  `%TEMP%\MacOsUsbSetup\setup-*.log`.

## Rechtliches

macOS ist Apple vorbehalten; die Installation auf Nicht-Apple-Hardware verstößt
gegen Apples Lizenzbedingungen. Dieses Werkzeug ist für Lern- und
Kompatibilitätszwecke gedacht. Die macOS-Abbildungen werden ausschließlich von
Apples eigenen Servern geladen.

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

Für Linux gibt es dasselbe als Kommandozeilen-Werkzeug: **`setup.sh`**.

## Ablauf

1. Start → Ladebalken während des Hardware-Scans
2. Kacheln aller lauffähigen macOS-Versionen (empfohlen / experimentell, mit Hinweisen)
3. Auswahl der Version
4. Auswahl des USB-Datenträgers (wird vollständig gelöscht)
5. Vorbereiten → EFI schreiben → macOS laden → prüfen
6. Neustart und vom USB booten

## Voraussetzungen

- Windows 10/11 x64
- .NET SDK 8 (nur zum Bauen; wird sonst automatisch per `winget` installiert)
- PowerShell 5.1+ (in Windows enthalten)
- Das Programm fragt beim Formatieren selbst nach Administratorrechten (UAC)
- Internetverbindung beim ersten Lauf (Apple-Recovery-Download)

## Bauen (Windows)

Doppelklick auf **`build.bat`** – oder in der Eingabeaufforderung:

```bat
build.bat
```

`build.bat` ruft `src\build.ps1` mit umgangener Ausführungsrichtlinie auf. Das
Skript lädt die offiziellen OpenCore-, Lilu-, VirtualSMC- und
WhateverGreen-Releases sowie `HfsPlus.efi` und die AMD-Vanilla-Kernel-Patches,
packt daraus `efi-payload.zip` (wird in die exe eingebettet) und veröffentlicht
`publish\setup.exe`. Das **.NET-8-SDK** wird automatisch gesucht und, falls es
fehlt, über `winget` installiert.

`setup.exe` kannst du danach manuell hochladen.

Optionen (werden an `src\build.ps1` durchgereicht):

- `build.bat -PayloadOnly` – nur die eingebettete EFI-Nutzlast neu bauen
- `build.bat -SkipPayload` – mit vorhandener Nutzlast veröffentlichen

## Gegenprüfung (optional)

Nach dem Erstellen des Sticks prüft **`debug_test-usb.bat`** einmalig Gerät und
USB und schreibt einen Report auf den Desktop mit **PASS/FAIL**: erwartete
OpenCore-/EFI-Dateien, `com.apple.recovery.boot`, Gültigkeit der `config.plist`
und die Programm-Logs. Braucht keine Administratorrechte.

## Linux: setup.sh

Gleicher Ablauf als textbasiertes Werkzeug, ohne Bauen direkt ausführbar:

```bash
sudo ./setup.sh
```

Benötigt: `bash`, `curl`, `lsblk`, `lscpu`, `lspci`, `sgdisk` (gdisk),
`mkfs.vfat` (dosfstools), `wipefs`/`partprobe` (util-linux), `unzip`, `python3`.
Fehlt etwas, nennt das Skript die Pakete. OpenCore/Kexte und die
macOS-Recovery werden zur Laufzeit von den offiziellen Quellen geladen; der
erzeugte Stick ist identisch zu dem der `setup.exe`.

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

- Eine FAT32-Partition (MBR), UEFI-bootfähig (bootet über EFI\BOOT\BOOTx64.efi)
- `EFI/` mit OpenCore, `OpenRuntime.efi`, `HfsPlus.efi` und den Basis-Kexts
- `EFI/OC/config.plist`, erzeugt für die erkannte Hardware
- `com.apple.recovery.boot/` mit `BaseSystem.dmg` + `BaseSystem.chunklist`

Vom Stick booten (UEFI), im OpenCore-Menü „macOS Base System" wählen, im
Festplattendienstprogramm das Ziel als APFS löschen und macOS installieren.

## Hinweise

- Der Stick ist recovery-basiert: Er bootet in die macOS-Wiederherstellung, die
  macOS während der Installation von Apple lädt. Beim Installieren ist daher eine
  Internetverbindung nötig.
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


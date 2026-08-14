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
| `Core/Graphics` | Intel-iGPU-Verzeichnis (Framebuffer + macOS-Obergrenze je Geräte-ID) |
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
- Laptops erhalten automatisch VoodooPS2 (Tastatur/Trackpad), AppleALC (Audio),
  die Basis-SSDTs (EC/USBX, PLUG, PNLF) und einen passenden MacBookPro-SMBIOS.
  OpenCore schreibt zusätzlich ein Protokoll (`opencore-*.txt`) auf den USB-Stick.
- Der Boot ist standardmäßig **sauber** (Apple-Logo, kein Verbose-Text); das
  OpenCore-Log geht weiter als Datei (`Target=65`). Für die Fehlersuche bei einem
  Boot-Hänger `-v keepsyms=1 debug=0x100` in `boot-args` ergänzen.
- **Audio:** Für Laptops wird `alcid=11` als erster Versuch gesetzt. Falls kein Ton:
  anderen Wert testen (T480 z. B. 11, 13, 21, 22, 27, 28, 29) – in `boot-args`
  `alcid=<n>` ändern.
- **SMBIOS-Serien** werden mit macserial modellrichtig erzeugt (iMessage-Basis;
  Apple verlangt fallweise eine einmalige Freischaltung).
- **Offline-Installer (kein Netz beim Installieren):** Optional (im USB-Schritt bzw.
  per Menü in `setup.sh`, ab macOS Big Sur, 32-GB-Stick). Der Stick bekommt eine
  zweite ExFAT-Partition mit dem kompletten `InstallAssistant.pkg` von Apple. Die
  Download-URL wird aus Apples Software-Update-Katalog gelesen (nicht geraten). Beim
  Installieren: „macOS Base System" booten → Terminal → `bash UnPlugged.command`
  (liegt mitsamt deutscher `INSTALL.txt` auf der Datenpartition) – installiert direkt
  vom Stick, ohne Apple-Download. Ohne diese Option bleibt es beim kleinen
  Online-Recovery-Stick.
- **Netzwerk im Installer:** Der Online-Recovery-Stick lädt macOS von Apple, braucht also
  Internet. Der zuverlässige Weg ist **Kabel/Ethernet** – dafür ist `IntelMausi`
  (Intel-Ethernet, deckt fast alle ThinkPads/Business-Laptops ab) immer dabei und
  funktioniert bereits in der Recovery. WLAN im Installer ist auf Intel-Karten
  unzuverlässig; `AirportItlwm` (natives Intel-WLAN, passend zur gewählten
  macOS-Version) wird mitgeliefert, greift aber vor allem im **installierten**
  System. Laptop ohne Ethernet: USB-Ethernet-Adapter mit **RTL8153**-Chip (läuft
  ohne Treiber). ASIX-`AX88179` (Original) funktioniert **nicht** ohne Treiber.
- CFG-Lock (gesperrtes MSR `0xE2`) ist in Standard-Laptop-BIOS meist aktiv und
  lässt sich dort nicht abschalten; macOS würde sonst früh mit einem Kernel-Panic
  abstürzen. Der passende Quirk wird je nach CPU automatisch gesetzt
  (`AppleXcpmCfgLock` ab Haswell, sonst `AppleCpuPmCfgLock`).
- Laptops erhalten zusätzlich `EnableWriteUnprotector` (Booter-Quirk): Stock-Laptop-
  Firmware lässt Laufzeitspeicher schreibgeschützt, wodurch der Kernel sonst früh
  auf einer Nur-Lese-Seite abstürzt („No mapping exists for frame pointer"). Die
  Speicher-Quirks entsprechen der geprüften T480-Referenzkonfiguration.
- Die iGPU-Framebuffer-ID kommt aus einem Verzeichnis (`Core/Graphics/IntelIgpuCatalog`),
  das jede Intel-Grafik-Generation von Sandy Bridge bis Ice Lake anhand der
  PCI-Geräte-ID abbildet – nicht anhand der CPU. So wird z. B. die UHD 620 im
  ThinkPad T480 (Kaby-Lake-R, `0x87C00000` + Spoof + Framebuffer-Patches) von der
  baugleichen HD 620 (Kaby Lake, `0x59160000`) unterschieden. Dasselbe Verzeichnis
  liefert auch die macOS-Obergrenze für die Kacheln, damit Framebuffer und
  Kompatibilität nie auseinanderlaufen. Eine unbekannte oder treiberlose Intel-iGPU
  (z. B. Tiger Lake und neuer) bekommt den VESA-Framebuffer (`-igfxvesa`), damit die
  Installation trotzdem ein Bild zeigt. `setup.sh` spiegelt dieselbe Tabelle.
- Die Kacheln zeigen für Intel-iGPUs die höchste sinnvolle Version (bei Kaby
  Lake z. B. Ventura), da neuere macOS-Versionen keine passenden Treiber mehr
  enthalten. Hängt der Bootvorgang bei `[EB|LOG:EXITBS:START]`, ist das ein
  Speicher-/Firmware-Thema – eine ältere Version (Ventura/Monterey) hilft am
  zuverlässigsten.
- Wird der Stick im Boot-Menü nicht angezeigt: im Firmware-Setup CSM
  deaktivieren bzw. „UEFI USB" aktivieren.
- Läuft ein Schritt auf einen Fehler, zeigt die Oberfläche eine fachliche
  Meldung samt Empfehlung. Vollständiges Protokoll:
  `%TEMP%\MacOsUsbSetup\setup-*.log`.

## Nachbesserung im installierten System (`scripts/…`)

Optionale Skripte fürs bereits laufende macOS. Die EFI-ändernden laufen mit
`sudo bash <datei>` und machen immer Backup + `plutil`-Prüfung (bei Fehler
automatischer Rückbau):

- **`scripts/postinstall-fixes.command`** – trägt Ton (AppleALC) und die
  Bluetooth-Kexte in die interne EFI ein und setzt die Boot-args `alcid=11`
  (Audio) und `-btlfxallowanyaddr` (Intel-BT bei NULL-Adresse).
- **`scripts/polish-fixes.command`** – Feinschliff: entfernt den veralteten
  `LegacyEnable`-Schlüssel (Boot-Meldung „OCS: No schema for LegacyEnable"),
  schaltet den OpenCore-/Recovery-Auswahlbildschirm ab (`ShowPicker=false`,
  direkt durchbooten) und sorgt für einen sauberen Apple-Logo-Boot.
- **`scripts/keyboard-iso-fix.command`** – sauberer, dauerhafter Tastatur-Fix
  **ohne** Fremdsoftware: entfernt einen evtl. früher gesetzten hidutil-Swap und
  lässt macOS die Tastatur als **ISO** erkennen (Tastatur-Einrichtungsassistent).
  Danach stimmen **alle** Tasten – nicht nur „<>|"/„^°" – und zwar **pro Tastatur
  getrennt**: interne + externe Windows-Tastaturen als ISO, eine Apple-ANSI-
  Tastatur bleibt ANSI. Das ist der Wurzel-Fix; der frühere globale Zwei-Tasten-
  Swap konnte eine korrekt erkannte Apple-Tastatur verdrehen. (Wer lieber eine
  App möchte: **Karabiner-Elements** kann dasselbe per Regel, installiert aber
  einen dauerhaften Treiber.)

### Kamera & Bluetooth: erst diagnostizieren, dann gezielt fixen

Interne Kamera und Intel-Bluetooth hängen beide am **internen USB-Bus**. Fehlt
eines/beides, ist die Ursache **nicht** immer dieselbe – blindes USB-Mapping kann
sogar funktionierende Ports (Fingerprint, SD, externe Buchsen) *rauswerfen*, weil
eine Map-Kext eine Positivliste ist. Deshalb zuerst messen:

1. **`scripts/hw-diagnose.command`** (nur lesend, kein `sudo`) sagt pro Gerät, ob
   es am USB-Bus auftaucht, welche Kexte geladen sind und was der nächste Schritt
   ist. Vorher im BIOS (F1) unter *Security → I/O Port Access* **Integrated
   Camera** und **Bluetooth** aktivieren, `Fn`+`F8` (Funk an) und den ThinkShutter
   öffnen.
2. **Bluetooth-Modul ist sichtbar, BT aber aus** → meist fehlt nur der Boot-arg:
   **`scripts/bt-anyaddr.command`** ergänzt `-btlfxallowanyaddr`. Kein USB-Mapping
   nötig.
3. **Kamera und/oder BT fehlen komplett am USB** (obwohl im BIOS aktiv) → das ist
   das 15-Port-Limit; dann **USB-Port-Mapping** nötig. Da rein hardwarespezifisch,
   läuft es interaktiv **direkt in macOS** mit CorpNewt **USBMap**
   (`https://github.com/corpnewt/USBMap`): `./USBMap.command` → *Discover Ports* →
   interne Kamera (Chicony/Bison/Sunplus) und Intel-BT (VID `0x8087`) als
   **connector type 255 (internal)** aktivieren, jede externe Buchse einmal mit
   USB2- **und** USB3-Gerät antippen, ≤ 15 Personalities je Controller behalten,
   `USBMap.kext` bauen. Die gebaute Kext dann sicher einspielen mit
   **`scripts/usb-map-install.command`** (`sudo bash usb-map-install.command
   [pfad/USBMap.kext]`): Backup, Eintrag in `Kernel→Add` (codeless), Entfernen der
   Discovery-Hilfskext, `XhciPortLimit=false` und `plutil`-Prüfung. `XhciPortLimit`
   bleibt **aus** (unter Ventura ohnehin unzuverlässig).

Neu erzeugte Sticks brauchen die ersten Punkte nicht mehr: `LegacyEnable` wird
nicht länger geschrieben, die auf die interne Platte kopierte EFI bootet nach dem
Offline-Install direkt ohne Auswahlbildschirm durch, und `-btlfxallowanyaddr` ist
für Laptops von Haus aus gesetzt. USB-Port-Mapping bleibt hardwarespezifisch und
damit ein bewusst manueller Schritt.

## Rechtliches

macOS ist Apple vorbehalten; die Installation auf Nicht-Apple-Hardware verstößt
gegen Apples Lizenzbedingungen. Dieses Werkzeug ist für Lern- und
Kompatibilitätszwecke gedacht. Die macOS-Abbildungen werden ausschließlich von
Apples eigenen Servern geladen.


# macOS auf ThinkPad – USB‑Installer

Ein Werkzeug, das einen bootfähigen **macOS‑Installations‑Stick** für ThinkPad‑/
Lenovo‑Laptops baut. Hardware wird erkannt, die passenden macOS‑Versionen als
Kacheln angezeigt, die gewählte Version von Apple geladen und ein auf die
Hardware zugeschnittener OpenCore‑Stick geschrieben.

**Ziel:** möglichst nichts von Hand nachrüsten. Kamera, Bluetooth, WLAN, Ton,
Grafik und Tastatur sind – soweit macOS es zulässt – **ab Werk** dabei.

---

## In 3 Schritten

**1. Stick bauen**
- **[setup.exe herunterladen](https://github.com/florianthepro/macos/releases/latest)** (Windows) – oder unter Linux `sudo ./setup.sh`.
- Starten → **macOS‑Version** wählen → **„Offline"** ankreuzen (empfohlen: installiert ohne Internet) → **USB‑Stick** wählen → **flashen** und warten.

**2. Installieren**
- Vom Stick booten (im Firmware‑Menü **UEFI USB** wählen; CSM/Legacy aus) → **„macOS Base System"**.
- **Offline:** Terminal öffnen und den bewährten Zweizeiler aus der `INSTALL.txt` ausführen (`cd "/Volumes/MACOS-DATA"` → `bash UnPlugged.command`). **Online:** „macOS installieren" wählen und dem Assistenten folgen.
- **Stick eingesteckt lassen.** Bei jedem Neustart im Boot‑Menü **„macOS Installer"** wählen (nicht „Base System"), später **„Macintosh HD"** – bis der Willkommensassistent kommt.

**3. Einmal `start-me.command`**
- Nach dem ersten Start von macOS liegt **`start-me.command`** auf dem Stick (bzw. Desktop). **Doppelklick** – das war's. Es:
  - kopiert OpenCore auf die **interne Platte** → ab jetzt bootet macOS **ohne Stick** (kein F12 mehr),
  - installiert das deutsche **Windows‑Tastaturlayout**,
  - sichert Kamera/Bluetooth ab, falls dein Modell nicht schon ab Werk versorgt ist,
  - und startet bei Bedarf **selbst** neu.
- Danach in **Systemeinstellungen → Tastatur → Eingabequellen** einmalig **„Deutsch – Windows (ThinkPad)"** hinzufügen. Diese eine Auswahl verlangt macOS zwingend selbst – alles andere läuft ohne Zutun.

---

## Was danach läuft

| Komponente | Zustand |
| --- | --- |
| **WLAN / Ethernet** | ab Werk (AirportItlwm / IntelMausi) |
| **Ton** (Lautsprecher/Mikro) | ab Werk (AppleALC) |
| **Grafik** | ab Werk (iGPU‑Framebuffer je Geräte‑ID) |
| **Batterieanzeige** | optional per `scripts/battery.command` (experimentell – auf dem Referenz‑T480 verursachte es einen Boot‑Hänger; das Skript beschreibt den Rettungsweg) |
| **Kamera + Bluetooth** | ab Werk auf der **T480‑Familie**; sonst richtet `start-me.command` die USB‑Portmap automatisch ein |
| **Tastatur** | Windows‑Layout via `start-me.command` – nur die Eingabequelle einmal anklicken |
| **iMessage/FaceTime** | gültige Seriennummern ab Werk; `scripts/imessage.command` setzt die ROM auf die echte MAC und führt durch die Anmeldung (Apple verlangt fallweise eine einmalige Freischaltung) |

macOS‑Versionen: die Fixes sind **nicht** versionsgebunden und laufen von Big Sur
bis zur jeweils für die Hardware sinnvollen Version.

---

## Details / Technik

<details>
<summary>Aufklappen</summary>

- **Ab Werk gebacken** (Laptops): OpenCore + Lilu/VirtualSMC/WhateverGreen,
  IntelMausi (Ethernet) und passendes AirportItlwm (WLAN), AppleALC (Ton),
  VoodooPS2 (Tastatur/Trackpad), Intel‑BT‑Kexte (IntelBluetoothFirmware +
  IntelBTPatcher + BlueToolFixup) mit Boot‑arg `-btlfxallowanyaddr`, Basis‑SSDTs
  (EC/USBX, PLUG, PNLF), gültige SMBIOS‑Seriennummern (macserial), sauberer Boot
  (kein `LegacyEnable`, kein Auswahlbildschirm), CFG‑Lock‑ und Speicher‑Quirks.
- **USB‑Portmap:** die internen Ports (Kamera/Bluetooth) werden von macOS
  standardmäßig übersprungen, weil die SMBIOS‑Werks‑Portmap sie ausblendet. Eine
  codeless `USBMap.kext` (Merge über `IOParentMatch → pcidebug`, interne Ports als
  Typ 255) überstimmt das. Für die **T480‑Familie** (UHD‑620‑iGPU `0x5917`) ist sie
  ab Werk drin; für andere Modelle baut `scripts/usb-fix.command` sie **generisch**
  aus dem laufenden System (extern = bereits enumeriert, interne HS → 255).
- **Warum ACPI‑Ansätze nicht helfen:** macOS baut die USB‑Ports aus den
  Controller‑Registern + der SMBIOS‑Werks‑Portmap, nicht aus den ACPI‑RHUB‑Ports –
  ein RHUB‑`_STA`‑Reset ist daher wirkungslos.
- **Skripte** (`scripts/…`, jeweils Backup + `plutil`‑Prüfung + Rückbau):
  `start-me.command` (der eine Nachlauf), `usb-fix.command` (USB‑Portmap generisch),
  `keyboard.command` (nur Layout), `camera.command` / `bluetooth.command`
  (Einzelgeräte), `usb-test.command` / `hw-diagnose.command` (nur lesende Diagnose),
  `offline-install.command` (Recovery‑Installer), `usb-map-install.command` /
  `postinstall-fixes.command` / `polish-fixes.command` (Fortgeschrittene/Altlasten).
  Das Tastaturlayout liegt in `assets/keyboard/`.
- **Bauen:** Windows `build.bat` (→ `publish\setup.exe`) bzw. Linux `sudo ./setup.sh`.
  `src/build.ps1` bündelt OpenCore/Kexte/macserial ins eingebettete `efi-payload.zip`.

</details>

## VCE – Virtual Compatible EFI (Teilprojekt)

Unter [`vce/`](vce/) entsteht **VCE**: eine EFI‑Umgebung mit dem Ziel, jedes
Betriebssystem kompatibel zu booten. Stufe 1 ist fertig nutzbar: ein
Boot‑Stick (iPXE), der sein **Installationsmenü von deinem eigenen Server**
lädt – Windows/Linux/BSD per Auswahl installieren, macOS über den Stick dieses
Hauptprojekts. `vce/build-vce.sh --server http://dein-server` baut den Stick,
`vce/server/` beschreibt die Serverseite. Die Ausbaustufen (OS‑Shims,
Firmware‑Virtualisierung) sind im [`vce/README.md`](vce/README.md) beschrieben.

## Rechtliches

macOS ist Apple vorbehalten; die Installation auf Nicht‑Apple‑Hardware verstößt
gegen Apples Lizenzbedingungen. Dieses Werkzeug ist für Lern‑ und
Kompatibilitätszwecke gedacht. Die macOS‑Abbildungen werden ausschließlich von
Apples eigenen Servern geladen.

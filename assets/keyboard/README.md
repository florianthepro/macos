# Windows-Tastaturlayout für macOS (`Windows-German.keylayout`)

Deutsches **Windows/IBM-PC**-Tastaturlayout für macOS. Es bildet die AltGr-Ebene
so ab, wie sie auf einer deutschen ThinkPad-/PC-Tastatur aufgedruckt ist –
anders als das Apple-Standardlayout:

| Zeichen | Windows/ThinkPad (dieses Layout) | Apple-Standard |
| --- | --- | --- |
| `@` | AltGr + Q | Option + L |
| `€` | AltGr + E | Option + E |
| `{ [ ] }` | AltGr + 7 8 9 0 | Option + 8 9 … |
| `\` | AltGr + ß | Option + Shift + 7 |
| `~` | AltGr + + | Option + N |
| `\|` | AltGr + `<`-Taste | Option + 7 |
| `² ³ µ` | AltGr + 2 / 3 / M | – |

Es ist zugleich für den Hackintosh-Fall gebaut, in dem macOS eine ISO-Tastatur
als ANSI erkennt: die Tasten `<>\|` und `^°` liefern damit ohne zusätzlichen
Tasten-Swap die richtigen Zeichen. Deshalb ersetzt dieses Layout den früheren
`hidutil`-Swap (beides zusammen würde doppelt vertauschen).

Installation macht `scripts/keyboard.command` automatisch (Kopie nach
`~/Library/Keyboard Layouts/`, danach in *Systemeinstellungen → Tastatur →
Eingabequellen* auswählen).

## Herkunft

Basiert auf dem frei verfügbaren „win-germany" Keylayout aus
`github.com/adrelino/mac-german-ibm-keylayout` (nur der Anzeigename wurde auf
„Deutsch – Windows (ThinkPad)" gesetzt). Tastaturbelegungen sind funktionale
Abbildungen; hier eingebunden für den Lern-/Kompatibilitätszweck dieses Projekts.
Passt für alle deutschen ThinkPad-/Lenovo-Modelle.

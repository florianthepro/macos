# VCE-Serverseite

Der VCE-Stick lädt beim Booten `http://DEIN-SERVER/vce/menu.ipxe`. Dieses
Verzeichnis beschreibt, was dafür auf dem Server liegen muss.

## Ordnerlayout (Webroot)

```
/vce/
├── menu.ipxe                  <- aus menu.ipxe.example anpassen (set base ...)
├── wimboot                    <- https://github.com/ipxe/wimboot/releases (Datei "wimboot")
├── win11/media/               <- Inhalt der Windows-ISO entpackt (Boot/, sources/, ...)
├── ubuntu/
│   ├── vmlinuz + initrd       <- aus der Ubuntu-Live-ISO (casper/)
│   └── ubuntu-24.04-live-server-amd64.iso
├── debian/
│   └── linux + initrd.gz      <- https://deb.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/debian-installer/amd64/
├── freebsd/
│   └── FreeBSD-…-bootonly.iso
└── memdisk                    <- aus syslinux (nur fuer BIOS-Memdisk-Boots)
```

## nginx-Beispiel

```nginx
server {
    listen 80;
    server_name mein-server.example;
    root /srv/www;                 # enthaelt den Ordner vce/
    location /vce/ {
        autoindex on;              # praktisch zum Testen
    }
}
```

Test vom Client: `curl -I http://mein-server.example/vce/menu.ipxe` → muss `200` liefern.

## Hinweise

- **Windows:** ISO nach `win11/media/` **entpacken** (nicht als .iso lassen) und
  `wimboot` daneben legen – das Menü bootet `boot.wim` direkt.
- **Große ISOs** übers Netz brauchen je nach NIC Geduld; kabelgebunden testen.
- **HTTPS:** iPXE von boot.ipxe.org kann HTTPS; bei eigener CA das Zertifikat
  einbauen oder schlicht HTTP im LAN nutzen.
- **macOS** bleibt Sache des OpenCore-Sticks aus dem Hauptprojekt (Apple lässt
  keine Netzinstallation von Fremdservern zu).

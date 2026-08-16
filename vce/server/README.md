# VCE-Serverseite

Der VCE-Stick (bzw. der OpenCore-Menüpunkt) lädt beim Booten
`http://DEIN-SERVER/vce/menu.ipxe`. Die Einrichtung übernimmt **ein Befehl**:

```bash
sudo ../setup-server.sh --url http://mein-server.example --root /srv/www --with-debian
```

Das erzeugt im Webroot:

```
/srv/www/vce/
├── menu.ipxe            <- fertig (deine URL eingesetzt)
├── wimboot              <- geladen (Windows-Bootkette)
├── debian/linux+initrd.gz  <- geladen (mit --with-debian)
├── win11/media/         <- HIER die Windows-ISO ENTPACKEN (Boot/, sources/, ...)
├── ubuntu/              <- vmlinuz + initrd (aus casper/) + ISO als ubuntu.iso
├── freebsd/             <- bootonly-ISO als freebsd-bootonly.iso
└── BEFUELLEN.txt        <- sagt genau, was noch fehlt
/srv/www/vce-nginx.conf.example  <- nginx-Beispiel (kopieren + aktivieren)
```

Test vom Client: `curl -I http://mein-server.example/vce/menu.ipxe` → muss `200` liefern.

## Hinweise

- **Windows:** ISO nach `win11/media/` **entpacken** (nicht als .iso lassen) –
  das Menü bootet `boot.wim` direkt über `wimboot`.
- **Große ISOs** übers Netz brauchen je nach NIC Geduld; kabelgebunden testen.
- **HTTPS:** iPXE von boot.ipxe.org kann HTTPS; im LAN reicht HTTP.
- **macOS** bleibt Sache des OpenCore-Sticks aus dem macOS-Projekt (Apple lässt
  keine Netzinstallation von Fremdservern zu).
- `menu.ipxe.example` in diesem Ordner ist die Referenzvorlage; `setup-server.sh`
  erzeugt die einsatzfertige Fassung mit deiner URL.

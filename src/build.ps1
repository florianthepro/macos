#Requires -Version 5.1
<#
    build.ps1 - assembles the bundled EFI payload from upstream releases and
    publishes setup.exe. Invoked by build.bat in the repository root.

    The application source contains none of the third-party boot binaries.
    This script fetches them from their official sources, packs a single
    efi-payload.zip that gets embedded into the executable, then publishes a
    self-contained single-file setup.exe. The .NET 8 SDK is located
    automatically, and installed via winget when missing.

    Usage:
        powershell -ExecutionPolicy Bypass -File src\build.ps1
        ... -PayloadOnly    # only refresh the embedded EFI payload
        ... -SkipPayload    # publish using the existing payload
#>
[CmdletBinding()]
param(
    [switch]$PayloadOnly,
    [switch]$SkipPayload,
    [string]$OpenCoreVersion = '1.0.7',
    [string]$LiluVersion     = '1.7.1',
    [string]$VirtualSmcVersion = '1.3.7',
    [string]$WhateverGreenVersion = '1.7.0',
    [string]$VoodooPS2Version = '2.3.7',
    [string]$IntelMausiVersion = '1.0.8',
    [string]$AirportItlwmVersion = 'v2.3.0',
    [string]$AppleAlcVersion = '1.9.2',
    [string]$IntelBtVersion  = 'v2.4.0',
    [string]$BrcmVersion     = '2.7.2'
)

$ErrorActionPreference = 'Stop'
# This script lives in src/, so the repository root is its parent.
$root      = Split-Path -Parent $PSScriptRoot
$assets    = Join-Path $root 'src/MacOsUsbSetup/Assets'
$cache     = Join-Path $root '.efi-cache'
$staging   = Join-Path $cache 'staging'
$payload   = Join-Path $assets 'efi-payload.zip'

function Get-Release([string]$repo, [string]$tag, [string]$assetPattern, [string]$outFile) {
    if (Test-Path $outFile) { return $outFile }
    $url = "https://github.com/$repo/releases/download/$tag/$assetPattern"
    Write-Host "  fetch $repo $tag -> $assetPattern"
    Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
    return $outFile
}

function Expand-Into([string]$zip, [string]$dest) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}

function Resolve-Dotnet {
    $found = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
    if ($found) { return $found }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'dotnet\dotnet.exe'),
        (Join-Path $env:LocalAppData 'Microsoft\dotnet\dotnet.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'dotnet nicht gefunden - .NET 8 SDK wird via winget installiert...'
        # Pipe to Out-Host so winget's stdout is displayed, not returned as the path.
        winget install --id Microsoft.DotNet.SDK.8 -e --source winget `
            --accept-package-agreements --accept-source-agreements | Out-Host
        foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    }

    throw @'
.NET 8 SDK nicht gefunden.
Installieren und build.bat erneut ausfuehren:
  winget install Microsoft.DotNet.SDK.8
oder herunterladen: https://dotnet.microsoft.com/download/dotnet/8.0
'@
}

function Build-Payload {
    Write-Host 'Assembling EFI payload from upstream releases...'
    New-Item -ItemType Directory -Force -Path $cache, $assets | Out-Null
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    $efi = New-Item -ItemType Directory -Force -Path (Join-Path $staging 'EFI')

    # --- OpenCore RELEASE (bootloader, drivers, boot binaries) ---
    $ocZip = Get-Release 'acidanthera/OpenCorePkg' $OpenCoreVersion "OpenCore-$OpenCoreVersion-RELEASE.zip" (Join-Path $cache 'oc.zip')
    $ocDir = Join-Path $cache 'oc'
    Expand-Into $ocZip $ocDir
    Copy-Item (Join-Path $ocDir 'X64/EFI/BOOT') (Join-Path $efi 'BOOT') -Recurse -Force
    Copy-Item (Join-Path $ocDir 'X64/EFI/OC')   (Join-Path $efi 'OC')   -Recurse -Force

    # macserial (OpenCorePkg utility) -> payload root, so setup.exe can mint a valid,
    # model-correct SMBIOS serial at runtime (prerequisite for iMessage/FaceTime).
    $macserial = Join-Path $ocDir 'Utilities/macserial/macserial.exe'
    if (Test-Path $macserial) { Copy-Item $macserial (Join-Path $staging 'macserial.exe') -Force }
    else { Write-Warning 'macserial.exe not found in OpenCore package' }

    # Recovery-side offline installer script -> payload root (written to the data partition).
    $offlineScript = Join-Path $root 'scripts/offline-install.command'
    if (Test-Path $offlineScript) { Copy-Item $offlineScript (Join-Path $staging 'offline-install.command') -Force }
    else { Write-Warning 'offline-install.command not found' }

    # The one post-install file + the keyboard layout -> payload root, so setup.exe can drop them
    # onto the stick for the user to double-click after first boot.
    $startMe = Join-Path $root 'scripts/start-me.command'
    if (Test-Path $startMe) { Copy-Item $startMe (Join-Path $staging 'start-me.command') -Force }
    else { Write-Warning 'start-me.command not found' }
    $keylayout = Join-Path $root 'assets/keyboard/Windows-German.keylayout'
    if (Test-Path $keylayout) { Copy-Item $keylayout (Join-Path $staging 'Windows-German.keylayout') -Force }
    else { Write-Warning 'Windows-German.keylayout not found' }

    $ocRoot   = Join-Path $efi 'OC'
    $drivers  = Join-Path $ocRoot 'Drivers'
    $kexts    = Join-Path $ocRoot 'Kexts'
    New-Item -ItemType Directory -Force -Path $kexts | Out-Null

    # Keep only the drivers we actually reference; drop the rest to stay minimal.
    Get-ChildItem $drivers -File | Where-Object { $_.Name -ne 'OpenRuntime.efi' } | Remove-Item -Force

    # --- HfsPlus.efi (read the HFS+ recovery image) from OcBinaryData ---
    $hfs = Join-Path $drivers 'HfsPlus.efi'
    Invoke-WebRequest -UseBasicParsing -OutFile $hfs `
        -Uri 'https://raw.githubusercontent.com/acidanthera/OcBinaryData/master/Drivers/HfsPlus.efi'

    # --- Base kexts required to boot the installer ---
    $kextSources = @(
        @{ repo = 'acidanthera/Lilu';          tag = $LiluVersion;          asset = "Lilu-$LiluVersion-RELEASE.zip";                   pick = 'Lilu.kext' },
        @{ repo = 'acidanthera/VirtualSMC';     tag = $VirtualSmcVersion;    asset = "VirtualSMC-$VirtualSmcVersion-RELEASE.zip";       pick = 'VirtualSMC.kext' },
        @{ repo = 'acidanthera/WhateverGreen';  tag = $WhateverGreenVersion; asset = "WhateverGreen-$WhateverGreenVersion-RELEASE.zip"; pick = 'WhateverGreen.kext' },
        @{ repo = 'acidanthera/IntelMausi';     tag = $IntelMausiVersion;    asset = "IntelMausi-$IntelMausiVersion-RELEASE.zip";       pick = 'IntelMausi.kext' },
        @{ repo = 'acidanthera/AppleALC';       tag = $AppleAlcVersion;      asset = "AppleALC-$AppleAlcVersion-RELEASE.zip";           pick = 'AppleALC.kext' }
    )
    foreach ($k in $kextSources) {
        $z = Get-Release $k.repo $k.tag $k.asset (Join-Path $cache ($k.pick + '.zip'))
        $ex = Join-Path $cache ($k.pick + '-x')
        Expand-Into $z $ex
        $src = Get-ChildItem $ex -Recurse -Directory -Filter $k.pick | Select-Object -First 1
        if (-not $src) { throw "kext $($k.pick) not found in $($k.asset)" }
        Copy-Item $src.FullName (Join-Path $kexts $k.pick) -Recurse -Force
    }

    # --- VoodooPS2 (laptop keyboard/trackpad); config references it only on laptops ---
    $vpZip = Get-Release 'acidanthera/VoodooPS2' $VoodooPS2Version "VoodooPS2Controller-$VoodooPS2Version-RELEASE.zip" (Join-Path $cache 'voodoops2.zip')
    $vpEx = Join-Path $cache 'voodoops2-x'
    Expand-Into $vpZip $vpEx
    $vpSrc = Get-ChildItem $vpEx -Recurse -Directory -Filter 'VoodooPS2Controller.kext' | Select-Object -First 1
    if (-not $vpSrc) { throw 'VoodooPS2Controller.kext not found' }
    Copy-Item $vpSrc.FullName (Join-Path $kexts 'VoodooPS2Controller.kext') -Recurse -Force

    # --- Intel Bluetooth (IntelBluetoothFirmware + IntelBTPatcher in one zip) + BlueToolFixup ---
    $btZip = Get-Release 'OpenIntelWireless/IntelBluetoothFirmware' $IntelBtVersion "IntelBluetooth-$IntelBtVersion.zip" (Join-Path $cache 'intelbt.zip')
    $btEx  = Join-Path $cache 'intelbt-x'; Expand-Into $btZip $btEx
    foreach ($bk in 'IntelBluetoothFirmware.kext','IntelBTPatcher.kext') {
        $s = Get-ChildItem $btEx -Recurse -Directory -Filter $bk | Select-Object -First 1
        if (-not $s) { throw "$bk not found" }
        Copy-Item $s.FullName (Join-Path $kexts $bk) -Recurse -Force
    }
    $brcmZip = Get-Release 'acidanthera/BrcmPatchRAM' $BrcmVersion "BrcmPatchRAM-$BrcmVersion-RELEASE.zip" (Join-Path $cache 'brcm.zip')
    $brcmEx  = Join-Path $cache 'brcm-x'; Expand-Into $brcmZip $brcmEx
    $btf = Get-ChildItem $brcmEx -Recurse -Directory -Filter 'BlueToolFixup.kext' | Select-Object -First 1
    if (-not $btf) { throw 'BlueToolFixup.kext not found' }
    Copy-Item $btf.FullName (Join-Path $kexts 'BlueToolFixup.kext') -Recurse -Force

    # --- USBMap.kext (codeless) for the ThinkPad T480 family: internal camera/BT ports as type 255.
    # Config references it only when the iGPU is 0x5917 (UHD 620). model is omitted so it applies on
    # whatever SMBIOS setup.exe chooses; IOParentMatch pcidebug 0:20:0 (00:14.0) + IOProbeScore win. ---
    $um = Join-Path $kexts 'USBMap.kext/Contents'
    New-Item -ItemType Directory -Force -Path $um | Out-Null
    function PortData([int]$n) { [Convert]::ToBase64String([byte[]]@($n,0,0,0)) }
    $ports = @(
        @('HS01',1,3),@('HS02',2,3),@('HS03',3,255),@('HS04',4,9),@('HS05',5,255),@('HS06',6,255),
        @('HS07',7,255),@('HS08',8,255),@('HS09',9,255),@('HS10',10,255),@('SS01',13,3),@('SS02',14,3),@('SS04',16,9)
    )
    $portXml = ($ports | ForEach-Object {
        "                    <key>$($_[0])</key>`n                    <dict><key>UsbConnector</key><integer>$($_[2])</integer><key>port</key><data>$(PortData $_[1])</data><key>usb-port-number</key><data>$(PortData $_[1])</data><key>usb-port-type</key><integer>$($_[2])</integer></dict>"
    }) -join "`n"
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.corpnewt.USBMap</string>
    <key>CFBundleName</key><string>USBMap</string>
    <key>CFBundlePackageType</key><string>KEXT</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>OSBundleRequired</key><string>Root</string>
    <key>IOKitPersonalities</key>
    <dict>
        <key>T480-XHC</key>
        <dict>
            <key>CFBundleIdentifier</key><string>com.apple.driver.AppleUSBHostMergeProperties</string>
            <key>IOClass</key><string>AppleUSBHostMergeProperties</string>
            <key>IOProviderClass</key><string>AppleUSBHostController</string>
            <key>IOProbeScore</key><integer>5000</integer>
            <key>IOParentMatch</key>
            <dict><key>IOPropertyMatch</key><dict><key>pcidebug</key><string>0:20:0</string></dict></dict>
            <key>IOProviderMergeProperties</key>
            <dict>
                <key>kUSBMuxEnabled</key><true/>
                <key>port-count</key><data>$(PortData 16)</data>
                <key>ports</key>
                <dict>
$portXml
                </dict>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
"@ | Set-Content -Path (Join-Path $um 'Info.plist') -Encoding UTF8

    # --- AirportItlwm (native Intel Wi-Fi) for the installed system, one bundle per macOS ---
    # The kext is always named AirportItlwm.kext; the macOS version lives only in the zip name.
    # Store each as AirportItlwm-<OS>.kext so the config can reference the matching release.
    $airport = @(
        @{ os = 'Catalina';   dest = 'Catalina' },
        @{ os = 'BigSur';     dest = 'BigSur' },
        @{ os = 'Monterey';   dest = 'Monterey' },
        @{ os = 'Ventura';    dest = 'Ventura' },
        @{ os = 'Sonoma14.4'; dest = 'Sonoma' }
    )
    foreach ($a in $airport) {
        $asset = "AirportItlwm_${AirportItlwmVersion}_stable_$($a.os).kext.zip"
        $z = Get-Release 'OpenIntelWireless/itlwm' $AirportItlwmVersion $asset (Join-Path $cache ("airport-$($a.dest).zip"))
        $ex = Join-Path $cache ("airport-$($a.dest)-x")
        Expand-Into $z $ex
        $src = Get-ChildItem $ex -Recurse -Directory -Filter 'AirportItlwm.kext' | Select-Object -First 1
        if (-not $src) { throw "AirportItlwm.kext not found in $asset" }
        Copy-Item $src.FullName (Join-Path $kexts "AirportItlwm-$($a.dest).kext") -Recurse -Force
    }

    # --- Laptop SSDTs (EC+USBX, CPU power plug, backlight); referenced only on laptops ---
    $acpiDir = Join-Path $ocRoot 'ACPI'
    New-Item -ItemType Directory -Force -Path $acpiDir | Out-Null
    $ssdtBase = 'https://raw.githubusercontent.com/dortania/Getting-Started-With-ACPI/master/extra-files/compiled'
    foreach ($ssdt in 'SSDT-EC-USBX-LAPTOP.aml', 'SSDT-PLUG-DRTNIA.aml', 'SSDT-PNLF.aml') {
        Write-Host "  fetch SSDT $ssdt"
        Invoke-WebRequest -UseBasicParsing -OutFile (Join-Path $acpiDir $ssdt) -Uri "$ssdtBase/$ssdt"
    }

    # OpenCore ships a placeholder Sample config; setup.exe writes the real one.
    Get-ChildItem $ocRoot -Filter '*.plist' | Remove-Item -Force -ErrorAction SilentlyContinue

    # AMD Vanilla kernel patches (only injected for AMD processors at write time).
    Invoke-WebRequest -UseBasicParsing -OutFile (Join-Path $staging 'amd-patches.plist') `
        -Uri 'https://raw.githubusercontent.com/AMD-OSX/AMD_Vanilla/master/patches.plist'

    $manifest = [ordered]@{
        openCore      = $OpenCoreVersion
        lilu          = $LiluVersion
        virtualSmc    = $VirtualSmcVersion
        whateverGreen = $WhateverGreenVersion
        voodooPS2     = $VoodooPS2Version
    } | ConvertTo-Json
    Set-Content -Path (Join-Path $staging 'payload.json') -Value $manifest -Encoding UTF8

    if (Test-Path $payload) { Remove-Item $payload -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $payload -Force
    Write-Host "EFI payload written: $payload"
}

function Publish-Exe {
    $dotnet = Resolve-Dotnet
    Write-Host "Publishing setup.exe (dotnet: $dotnet)..."
    $proj = Join-Path $root 'src/MacOsUsbSetup/MacOsUsbSetup.csproj'
    $out  = Join-Path $root 'publish'
    & $dotnet publish $proj -c Release -r win-x64 -o $out
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish fehlgeschlagen' }
    Write-Host ("Fertig: {0}" -f (Join-Path $out 'setup.exe'))
}

if (-not $SkipPayload) { Build-Payload }
if (-not $PayloadOnly) { Publish-Exe }

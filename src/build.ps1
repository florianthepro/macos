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
    [string]$VoodooPS2Version = '2.3.7'
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
        @{ repo = 'acidanthera/WhateverGreen';  tag = $WhateverGreenVersion; asset = "WhateverGreen-$WhateverGreenVersion-RELEASE.zip"; pick = 'WhateverGreen.kext' }
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

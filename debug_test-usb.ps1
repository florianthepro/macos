# debug_test-usb.ps1 - prueft Geraet + vorbereiteten USB und schreibt einen Report,
# um zu verifizieren, ob setup.exe korrekt gearbeitet hat. Laeuft ohne Admin.
$ErrorActionPreference = 'SilentlyContinue'

$script:lines = New-Object System.Collections.Generic.List[string]
$script:fail  = New-Object System.Collections.Generic.List[string]

function W([string]$s) { $script:lines.Add($s); Write-Host $s }

function FmtSize([long]$b) {
    if     ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
    else                { "$b B" }
}

function Chk([string]$path, [string]$label, [long]$minBytes = 0) {
    $it = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $it) { W ("  [FEHLT] {0}" -f $label); $script:fail.Add("$label fehlt"); return $false }
    if ($it.PSIsContainer) { W ("  [OK]    {0}" -f $label); return $true }
    $sz = $it.Length
    if ($minBytes -gt 0 -and $sz -lt $minBytes) {
        W ("  [KLEIN] {0} ({1}) - erwartet > {2}" -f $label, (FmtSize $sz), (FmtSize $minBytes))
        $script:fail.Add("$label zu klein"); return $false
    }
    W ("  [OK]    {0} ({1})" -f $label, (FmtSize $sz)); return $true
}

W '==== macOS USB Setup - Gegenpruefung ===='
W ('Zeit   : ' + (Get-Date))
W ('Rechner: ' + $env:COMPUTERNAME)
W ''

# --- System ---
W '--- System ---'
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
W ('CPU    : ' + $cpu.Name.Trim() + '  [' + $cpu.Description + ', ' + $cpu.NumberOfCores + ' Kerne]')
foreach ($g in Get-CimInstance Win32_VideoController) {
    if ($g.PNPDeviceID -match 'VEN_([0-9A-Fa-f]{4}).*DEV_([0-9A-Fa-f]{4})') { $id = "$($Matches[1]):$($Matches[2])" } else { $id = '????:????' }
    W ('GPU    : ' + $g.Name + '  [' + $id + ']')
}
$cs = Get-CimInstance Win32_ComputerSystem
W ('RAM    : ' + (FmtSize $cs.TotalPhysicalMemory))
$gptSys = Get-CimInstance Win32_DiskPartition | Where-Object { $_.Type -like 'GPT*' } | Select-Object -First 1
W ('Firmware: ' + $(if ($gptSys) { 'UEFI (Systemdatentraeger ist GPT)' } else { 'unbekannt / evtl. Legacy' }))
W ''

# --- USB disks ---
W '--- USB-Datentraeger ---'
$usb = Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' -or $_.MediaType -like 'Removable*' }
if (-not $usb) { W '  (keine USB-Datentraeger gefunden)' }
foreach ($d in $usb) {
    $letters = @()
    foreach ($p in (Get-CimAssociatedInstance -InputObject $d -ResultClassName Win32_DiskPartition)) {
        foreach ($ld in (Get-CimAssociatedInstance -InputObject $p -ResultClassName Win32_LogicalDisk)) { $letters += $ld.DeviceID }
    }
    W ('  Disk ' + $d.Index + ': ' + $d.Model.Trim() + '  ' + (FmtSize $d.Size) + '  Laufwerke: ' + ($letters -join ', '))
}
W ''

# --- target volume (what the exe should have produced) ---
W '--- Ziel-Volume (Label MACOS-USB) ---'
$target = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.VolumeLabel -eq 'MACOS-USB' } | Select-Object -First 1
$verdict = 'FAIL'
if (-not $target) {
    W '  KEIN vorbereiteter USB gefunden (Volume-Label MACOS-USB fehlt).'
    W '  -> setup.exe wurde nicht (vollstaendig) ausgefuehrt, oder ein anderer Stick.'
    $script:fail.Add('kein MACOS-USB Volume')
}
else {
    $r = $target.RootDirectory.FullName
    W ('  Laufwerk: ' + $r)
    W ('  Format  : ' + $target.DriveFormat + '   Groesse: ' + (FmtSize $target.TotalSize) + '   Frei: ' + (FmtSize $target.AvailableFreeSpace))
    if ($target.DriveFormat -ne 'FAT32') { $script:fail.Add('Format nicht FAT32') }

    W ''
    W '  EFI / OpenCore:'
    Chk (Join-Path $r 'EFI\BOOT\BOOTx64.efi')            'EFI\BOOT\BOOTx64.efi'            | Out-Null
    Chk (Join-Path $r 'EFI\OC\OpenCore.efi')             'EFI\OC\OpenCore.efi'             | Out-Null
    $cfgOk = Chk (Join-Path $r 'EFI\OC\config.plist')    'EFI\OC\config.plist' 200
    Chk (Join-Path $r 'EFI\OC\Drivers\OpenRuntime.efi')  'EFI\OC\Drivers\OpenRuntime.efi'  | Out-Null
    Chk (Join-Path $r 'EFI\OC\Drivers\HfsPlus.efi')      'EFI\OC\Drivers\HfsPlus.efi'      | Out-Null
    Chk (Join-Path $r 'EFI\OC\Kexts\Lilu.kext')          'EFI\OC\Kexts\Lilu.kext'          | Out-Null
    Chk (Join-Path $r 'EFI\OC\Kexts\VirtualSMC.kext')    'EFI\OC\Kexts\VirtualSMC.kext'    | Out-Null
    Chk (Join-Path $r 'EFI\OC\Kexts\WhateverGreen.kext') 'EFI\OC\Kexts\WhateverGreen.kext' | Out-Null

    W ''
    W '  macOS Recovery:'
    Chk (Join-Path $r 'com.apple.recovery.boot\BaseSystem.dmg')       'com.apple.recovery.boot\BaseSystem.dmg' (200MB) | Out-Null
    Chk (Join-Path $r 'com.apple.recovery.boot\BaseSystem.chunklist') 'com.apple.recovery.boot\BaseSystem.chunklist' 1 | Out-Null

    if ($cfgOk) {
        $cfg = Get-Content -LiteralPath (Join-Path $r 'EFI\OC\config.plist') -Raw
        $smb = if ($cfg -match '<key>SystemProductName</key>\s*<string>([^<]+)</string>') { $Matches[1] } else { '?' }
        $kx  = ([regex]::Matches($cfg, '<key>BundlePath</key>')).Count
        $ok  = ($cfg -match '<plist' -and $cfg -match '</plist>')
        W ''
        W ('  config.plist: ' + $(if ($ok) { 'gueltig' } else { 'UNGUELTIG' }) + ", SMBIOS=$smb, Kexts=$kx")
        if (-not $ok) { $script:fail.Add('config.plist ungueltig') }
    }

    if ($script:fail.Count -eq 0) { $verdict = 'PASS' }
}
W ''

# --- program logs ---
W '--- Programm-Logs (%TEMP%\MacOsUsbSetup) ---'
$logdir   = Join-Path $env:TEMP 'MacOsUsbSetup'
$setupLog = Get-ChildItem $logdir -Filter 'setup-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
$crashLog = Get-ChildItem $logdir -Filter 'crash-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($setupLog) {
    W ('  setup-Log: ' + $setupLog.Name)
    W ('  ERROR-Zeilen: ' + @(Select-String -Path $setupLog.FullName -Pattern 'ERROR').Count)
    W '  --- letzte 15 Zeilen ---'
    Get-Content $setupLog.FullName -Tail 15 | ForEach-Object { W ('    ' + $_) }
}
else { W '  (kein setup-Log gefunden)' }
if ($crashLog) {
    W ''
    W ('  CRASH-Log: ' + $crashLog.Name + '  <-- die App ist auf einen Fehler gelaufen')
    Get-Content $crashLog.FullName | Select-Object -First 20 | ForEach-Object { W ('    ' + $_) }
    $script:fail.Add('crash-log vorhanden'); $verdict = 'FAIL'
}
W ''

if ($script:fail.Count -gt 0) {
    W '--- Probleme ---'
    $script:fail | ForEach-Object { W ('  - ' + $_) }
    W ''
}
W ("==== ERGEBNIS: $verdict ====")

$dest = Join-Path ([Environment]::GetFolderPath('Desktop')) ('macos-usb-debug-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$script:lines -join "`r`n" | Out-File -LiteralPath $dest -Encoding UTF8
Write-Host ''
Write-Host ('Report gespeichert: ' + $dest)

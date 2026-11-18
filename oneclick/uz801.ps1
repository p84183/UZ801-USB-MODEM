<#
.SYNOPSIS
  One-click backup / OpenWRT flash / restore for the UZ801 v3.2 (MSM8916) USB modem on Windows.

.DESCRIPTION
  Actions:
    setup         Check adb / fastboot / python and install the bkerler "edl" tool into .\tools\edl
    backup        Put the dongle in EDL and dump the whole flash plus every partition (read-only)
    flash         Flash OpenWRT (HandsomeMod-UZ801 release) over fastboot, using THIS dongle's modem
                  partitions instead of the ones bundled in the release. Needs a verified backup.
    restore-modem Write ONLY modemst1, modemst2, fsg, fsc back from a backup (IMEI / signal recovery)
    restore-full  Write the whole full_backup.bin back (return to the exact stock state)

  Backups land in .\backups\<timestamp>\ and are git-ignored on purpose: modemst1/2, fsg and fsc
  hold this device's own IMEI and RF calibration. Never commit or share them.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File uz801.ps1 backup
  powershell -ExecutionPolicy Bypass -File uz801.ps1 flash -ImagePath C:\Downloads\OpenWRT-UZ801_2026.tar.xz
  powershell -ExecutionPolicy Bypass -File uz801.ps1 restore-modem -BackupDir .\backups\20261118-120000
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('setup', 'backup', 'flash', 'restore-modem', 'restore-full')]
    [string]$Action,

    # Backup folder to use for flash / restore. Defaults to the newest folder under .\backups
    [string]$BackupDir,

    # OpenWRT release archive (.tar.xz / .zip). Either a local path or a URL to download.
    [string]$ImagePath,
    # Default: mirror of HandsomeMod-UZ801 v1.0-alpha on peng's pCloud
    # (original: https://github.com/AlienWolfX/HandsomeMod-UZ801/releases/download/v1.0-alpha/OpenWRT-UZ801_2026.tar.xz)
    [string]$ImageUrl = 'https://filedn.com/l80M1m5GL7NXLyhbNmnccOu/UZ801-USB-MODEM/openwrt/OpenWRT-UZ801_2026.tar.xz',
    # SHA256 of the archive; a mismatch aborts the flash. Pass -ImageSha256 '' to skip when using another image.
    [string]$ImageSha256 = 'd3d933f2a45024967000fbac8bd18f5cb53a53882916b4c0ba3d777c86886e32',

    # Skip the typed "YES" confirmation (not recommended)
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root       = $PSScriptRoot
$ToolsDir   = Join-Path $Root 'tools'
$EdlDir     = Join-Path $ToolsDir 'edl'
$BackupRoot = Join-Path $Root 'backups'
$WorkDir    = Join-Path $Root 'work'
$ModemParts = @('modemst1', 'modemst2', 'fsg', 'fsc')

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Confirm-Danger($what) {
    if ($Force) { return }
    Warn $what
    $a = Read-Host 'Type YES (uppercase) to continue'
    if ($a -cne 'YES') { Die 'Cancelled.' }
}

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Get-Python {
    foreach ($c in 'python', 'py', 'python3') { if (Test-Cmd $c) { return $c } }
    Die 'Python 3 not found. Install it from https://www.python.org/downloads/ (tick "Add to PATH").'
}

function Invoke-Edl {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$EdlArgs)
    $py = Get-Python
    $script = Join-Path $EdlDir 'edl'
    if (-not (Test-Path $script)) { Die 'edl tool missing. Run: uz801.ps1 setup' }
    Info "edl $($EdlArgs -join ' ')"
    & $py $script @EdlArgs
    if ($LASTEXITCODE -ne 0) { Die "edl failed (exit $LASTEXITCODE)." }
}

function Test-EdlDevice {
    # Qualcomm HS-USB QDLoader 9008 = VID_05C6&PID_9008
    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -match 'VID_05C6&PID_9008' }
    return [bool]$d
}

function Enter-Edl {
    if (Test-EdlDevice) { Ok 'Device already in EDL (05C6:9008).'; return }
    if (Test-Cmd 'adb') {
        $devs = (& adb devices) -split "`n" | Where-Object { $_ -match "`tdevice" }
        if ($devs) {
            Info 'Rebooting to EDL via adb...'
            & adb reboot edl | Out-Null
        } elseif ((Test-Cmd 'fastboot') -and ((& fastboot devices) -match 'fastboot')) {
            Info 'Device in fastboot, trying "fastboot oem reboot edl"...'
            & fastboot oem reboot edl | Out-Null
        }
    }
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-EdlDevice) { Ok 'Device in EDL (05C6:9008).'; return }
        Start-Sleep -Seconds 1
    }
    Warn 'Device did not show up as Qualcomm 9008.'
    Warn ' - Stock firmware: enable ADB first at http://192.168.100.1/usbdebug.html'
    Warn ' - Or: unplug, short the board EDL pads (or USB D+ to GND), plug in, release.'
    Warn ' - Windows needs the WinUSB driver on the 9008 device (use Zadig once).'
    Read-Host 'Press Enter once the device is in EDL (or Ctrl+C to abort)' | Out-Null
    if (-not (Test-EdlDevice)) { Die 'Still no EDL device.' }
}

function Get-BackupDir {
    if ($BackupDir) { $d = Resolve-Path $BackupDir -ErrorAction SilentlyContinue }
    else {
        $d = Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object FullName
    }
    if (-not $d) { Die "No backup found in $BackupRoot. Run: uz801.ps1 backup" }
    return "$d"
}

function Test-Backup($dir, [switch]$NeedFull) {
    $hashFile = Join-Path $dir 'SHA256SUMS.txt'
    if (-not (Test-Path $hashFile)) { Die "$dir has no SHA256SUMS.txt; not a complete backup." }
    foreach ($p in $ModemParts) {
        if (-not ((Test-Path (Join-Path $dir "partitions\$p.bin")) -or (Test-Path (Join-Path $dir "partitions\$p.img")))) { Die "Backup is missing $p" }
    }
    if ($NeedFull -and -not (Test-Path (Join-Path $dir 'full_backup.bin'))) { Die 'Backup is missing full_backup.bin' }
    Info "Verifying hashes in $dir ..."
    foreach ($line in Get-Content $hashFile) {
        if ($line -notmatch '^([0-9a-f]{64})\s+(.+)$') { continue }
        $f = Join-Path $dir $Matches[2]
        if (-not (Test-Path $f)) { Die "Missing $($Matches[2])" }
        if ((Get-FileHash $f -Algorithm SHA256).Hash.ToLower() -ne $Matches[1]) { Die "Hash mismatch: $($Matches[2])" }
    }
    Ok 'Backup verified.'
}

# ---------------------------------------------------------------- actions

function Do-Setup {
    foreach ($c in 'adb', 'fastboot', 'git') {
        if (Test-Cmd $c) { Ok "$c found" } else { Warn "$c not found (install Android platform-tools / Git for Windows and add to PATH)" }
    }
    $py = Get-Python; Ok "python: $py"
    New-Item -ItemType Directory -Force $ToolsDir | Out-Null
    if (-not (Test-Path $EdlDir)) {
        Info 'Cloning bkerler/edl ...'
        & git clone --recurse-submodules https://github.com/bkerler/edl $EdlDir
        if ($LASTEXITCODE -ne 0) { Die 'git clone failed.' }
    }
    Info 'Installing edl Python requirements...'
    & $py -m pip install -r (Join-Path $EdlDir 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { Die 'pip install failed.' }
    Ok 'Setup done. If the dongle shows as "QUSB_BULK" / 9008 without a driver, install WinUSB on it with Zadig (https://zadig.akeo.ie/).'
}

function Do-Backup {
    $dir = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Force (Join-Path $dir 'partitions') | Out-Null
    if (Test-Cmd 'adb') {
        $devs = (& adb devices) -split "`n" | Where-Object { $_ -match "`tdevice" }
        if ($devs) {
            Info 'Saving device info via adb...'
            & adb shell getprop > (Join-Path $dir 'getprop.txt')
            & adb shell cat /proc/partitions > (Join-Path $dir 'partitions.txt')
        }
    }
    Enter-Edl
    Invoke-Edl rl (Join-Path $dir 'partitions') --genxml
    Invoke-Edl rf (Join-Path $dir 'full_backup.bin')
    foreach ($p in $ModemParts) {
        if (-not (Test-Path (Join-Path $dir "partitions\$p.bin"))) { Die "Partition dump has no $p.bin; check the edl output." }
    }
    Info 'Writing SHA256SUMS.txt ...'
    Get-ChildItem $dir -Recurse -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object {
        $rel = $_.FullName.Substring($dir.Length + 1)
        '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $rel
    } | Set-Content (Join-Path $dir 'SHA256SUMS.txt') -Encoding ascii
    Invoke-Edl reset
    Ok "Backup complete: $dir"
    Warn 'Copy this folder somewhere safe (off this PC too). It holds your IMEI; do not share it.'
}

function Get-Image {
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    if ($ImagePath) {
        if (-not (Test-Path $ImagePath)) { Die "Image not found: $ImagePath" }
        $archive = (Resolve-Path $ImagePath).Path
    } else {
        $archive = Join-Path $WorkDir ([IO.Path]::GetFileName(([Uri]$ImageUrl).AbsolutePath))
        if (-not (Test-Path $archive)) {
            Info "Downloading $ImageUrl"
            Invoke-WebRequest -Uri $ImageUrl -OutFile $archive -UseBasicParsing
        }
    }
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
    Info "Image SHA256: $hash"
    if ($ImageSha256 -and $hash -ne $ImageSha256.ToLower()) { Die 'Image SHA256 does not match -ImageSha256.' }

    $out = Join-Path $WorkDir 'openwrt'
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Force $out | Out-Null
    Info 'Extracting...'
    & tar -xf $archive -C $out   # Windows 10+ ships bsdtar, which handles .tar.xz and .zip
    if ($LASTEXITCODE -ne 0) { Die 'Extract failed.' }
    $flash = Get-ChildItem $out -Recurse -Filter 'flash.bat' | Select-Object -First 1
    if (-not $flash) { Die 'No flash.bat inside the archive; unexpected release layout.' }
    return $flash
}

function Wait-Fastboot {
    for ($i = 0; $i -lt 60; $i++) {
        if ((& fastboot devices) -match 'fastboot') { return }
        Start-Sleep -Seconds 1
    }
    Die 'Device did not appear in fastboot within 60 s.'
}

function Invoke-Fastboot {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$FbArgs)
    Info "fastboot $($FbArgs -join ' ')"
    & fastboot @FbArgs
    if ($LASTEXITCODE -ne 0) { Die "fastboot $($FbArgs -join ' ') failed. Backups: $dir" }
}

function Find-BackupPart($dir, $name) {
    foreach ($ext in 'bin', 'img') {
        $f = Join-Path $dir "partitions\$name.$ext"
        if (Test-Path $f) { return $f }
    }
    Die "Backup has no partitions\$name.bin/.img"
}

# Re-implements the release flash.bat step by step (fastboot only, no EDL needed), with one change:
# the release ships modemst1/modemst2/fsg from ANOTHER unit and only replaces them if
# "fastboot oem dump" succeeds. We always overwrite them with THIS dongle's backup first.
function Do-Flash {
    $dir = Get-BackupDir
    Test-Backup $dir -NeedFull
    if (-not (Test-Cmd 'fastboot')) { Die 'fastboot not found.' }
    $flash = Get-Image
    $pkg = $flash.DirectoryName
    foreach ($f in 'aboot.bin','boot.img','rootfs.img','sbl1.mbn','rpm.mbn','tz.mbn','hyp.mbn','sbc_1.0_8016.bin','gpt_both0.bin') {
        if (-not (Test-Path (Join-Path $pkg $f))) { Die "Release package is missing $f" }
    }
    Confirm-Danger "This replaces the partition table, ERASES stock Android and flashes OpenWRT. Going back to stock later needs EDL (Zadig + restore-full). Backup in use: $dir"

    Info 'Copying THIS dongle''s modemst1/modemst2/fsg/fsc over the release''s bundled copies...'
    foreach ($p in $ModemParts) { Copy-Item (Find-BackupPart $dir $p) (Join-Path $pkg "$p.bin") -Force }

    Push-Location $pkg
    try {
        Info 'Stage 1: reboot to bootloader, install the OpenWRT aboot'
        & adb reboot bootloader | Out-Null
        Wait-Fastboot
        Invoke-Fastboot erase boot
        Invoke-Fastboot flash aboot aboot.bin
        Invoke-Fastboot reboot
        Start-Sleep -Seconds 5
        Wait-Fastboot

        Info 'Stage 2: new partition table, firmware, this dongle''s modem data, OpenWRT'
        Invoke-Fastboot flash partition gpt_both0.bin
        Invoke-Fastboot flash hyp hyp.mbn
        Invoke-Fastboot flash rpm rpm.mbn
        Invoke-Fastboot flash sbl1 sbl1.mbn
        Invoke-Fastboot flash tz tz.mbn
        foreach ($p in 'fsc', 'fsg', 'modemst1', 'modemst2') { Invoke-Fastboot flash $p "$p.bin" }
        Invoke-Fastboot flash aboot aboot.bin
        Invoke-Fastboot flash cdt sbc_1.0_8016.bin
        Invoke-Fastboot erase boot
        Invoke-Fastboot erase rootfs
        Invoke-Fastboot flash boot boot.img
        Invoke-Fastboot flash rootfs rootfs.img
        Invoke-Fastboot reboot
    } finally { Pop-Location }
    Ok 'Flash finished. Expect red/blue LED blinking, then http://192.168.1.1'
    Warn 'No signal? See wiki Troubleshooting (Changing Modem Region).'
}

function Do-RestoreModem {
    $dir = Get-BackupDir
    Test-Backup $dir
    Confirm-Danger "This overwrites modemst1, modemst2, fsg, fsc with the copies in $dir. Only use a backup from THIS dongle."
    Enter-Edl
    foreach ($p in $ModemParts) { Invoke-Edl w $p (Find-BackupPart $dir $p) }
    Invoke-Edl reset
    Ok 'Modem partitions restored.'
}

function Do-RestoreFull {
    $dir = Get-BackupDir
    Test-Backup $dir -NeedFull
    Confirm-Danger "This overwrites the ENTIRE flash with $dir\full_backup.bin (back to the state at backup time)."
    Enter-Edl
    Invoke-Edl wf (Join-Path $dir 'full_backup.bin')
    Invoke-Edl reset
    Ok 'Full restore done.'
}

switch ($Action) {
    'setup'         { Do-Setup }
    'backup'        { Do-Backup }
    'flash'         { Do-Flash }
    'restore-modem' { Do-RestoreModem }
    'restore-full'  { Do-RestoreFull }
}

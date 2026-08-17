#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$DeviceId = 'ACPI\RPI000F\0'
$LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RPi5Fan-install.log'
$PackageDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step([string]$Message) {
    Write-Host "`n===== $Message ====="
}

function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

Start-Transcript -Path $LogPath -Append | Out-Null
try {
    Write-Host 'RPi5Fan One Shot Installer v0.1.1'
    Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Windows: $([Environment]::OSVersion.VersionString)"
    Write-Host "Device: $DeviceId"
    Write-Host "Package: $PackageDir"

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required.'
    }

    $required = 'Rpi5Fan.inf','Rpi5Fan.sys','rpi5fan.cat','Rpi5Fan.cer'
    foreach ($name in $required) {
        $path = Join-Path $PackageDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Missing package file: $name"
        }
    }
    Write-Host 'OK: Driver files located.'

    $infPath = Join-Path $PackageDir 'Rpi5Fan.inf'
    $infText = Get-Content -LiteralPath $infPath -Raw
    if ($infText -notmatch 'ACPI\\RPI000F' -or $infText -notmatch 'NTARM64') {
        throw 'INF does not advertise the expected ARM64 ACPI\RPI000F match.'
    }
    if ($infText -notmatch 'DriverVer\s*=\s*08/17/2026\s*,\s*0\.1\.1\.0') {
        throw 'Unexpected driver version. Expected 0.1.1.0.'
    }
    Write-Host 'OK: INF hardware, architecture, and v0.1.1 version verified.'

    $devicePresent = Test-Path 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\ACPI\RPI000F\0'
    if (-not $devicePresent) {
        throw 'ACPI\RPI000F\0 is not present. Install/boot the companion fan-enabled RPi5 UEFI first.'
    }
    Write-Host 'OK: ACPI\RPI000F detected.'

    Write-Step 'TESTSIGNING check'
    $bcd = & bcdedit.exe /enum '{current}' 2>&1 | Out-String
    Write-Host $bcd.TrimEnd()
    if ($bcd -notmatch '(?im)^testsigning\s+Yes\s*$') {
        Write-Host 'TESTSIGNING is not enabled. Enabling it now...'
        Invoke-Native bcdedit.exe /set testsigning on
        Write-Warning 'TESTSIGNING was enabled. Reboot Windows, then run this same installer again.'
        exit 3010
    }
    Write-Host 'OK: TESTSIGNING already enabled.'

    Write-Step 'Certificate installation'
    Invoke-Native certutil.exe -addstore Root (Join-Path $PackageDir 'Rpi5Fan.cer')
    Invoke-Native certutil.exe -addstore TrustedPublisher (Join-Path $PackageDir 'Rpi5Fan.cer')

    Write-Step 'Driver installation'
    Push-Location $PackageDir
    try {
        Invoke-Native pnputil.exe /add-driver Rpi5Fan.inf /install
    }
    finally {
        Pop-Location
    }

    Write-Step 'PnP rescan and restart'
    Invoke-Native pnputil.exe /scan-devices
    & pnputil.exe /restart-device $DeviceId
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Device restart returned exit code $LASTEXITCODE; continuing with status check."
    }
    Start-Sleep -Seconds 2

    Write-Step 'Installed driver candidates'
    & pnputil.exe /enum-devices /instanceid $DeviceId /drivers

    Write-Step 'Final device status'
    $device = Get-PnpDevice -InstanceId $DeviceId -ErrorAction SilentlyContinue
    if ($null -eq $device) {
        throw 'The fan ACPI device disappeared after installation.'
    }
    $device | Format-List Status,Class,FriendlyName,InstanceId,Problem

    $problemStatus = Get-PnpDeviceProperty -InstanceId $DeviceId -KeyName 'DEVPKEY_Device_ProblemStatus' -ErrorAction SilentlyContinue
    if ($problemStatus) {
        $problemStatus | Format-List KeyName,Type,Data
    }

    if ($device.Status -ne 'OK' -or [string]$device.Problem -ne 'CM_PROB_NONE') {
        Write-Step 'Automatic SetupAPI diagnostics'
        $setupLog = 'C:\Windows\INF\setupapi.dev.log'
        if (Test-Path $setupLog) {
            Select-String -Path $setupLog -Pattern 'RPI000F','Rpi5Fan' -Context 5,15 |
                Select-Object -Last 100 |
                ForEach-Object { $_.ToString() }
        }
        throw "Driver installed but device is not healthy: Status=$($device.Status), Problem=$($device.Problem)"
    }

    Write-Host "`nSUCCESS: Raspberry Pi 5 Active Cooler driver v0.1.1 is installed and running."
    Write-Host "Log: $LogPath"
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}

#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$DeviceId = 'ACPI\RPI000F\0'
$ExpectedDriverVersion = '2026.8.17.3'
$ExpectedProvider = 'RPi5 UEFI Community'
$LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RPi5Fan-install.log'
$PackageDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RebootRequired = $false

function Write-Step([string]$Message) {
    Write-Host "`n===== $Message ====="
}

function Invoke-NativeAllowed {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][int[]]$AllowedExitCodes,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    $code = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $code) {
        throw "$FilePath failed with exit code $code"
    }
    return $code
}

function Get-DevicePropertyData([string]$KeyName) {
    $property = Get-PnpDeviceProperty -InstanceId $DeviceId -KeyName $KeyName -ErrorAction SilentlyContinue
    if ($null -eq $property) {
        return $null
    }
    return [string]$property.Data
}

function Get-SelectedDriverState {
    [pscustomobject]@{
        InfPath  = Get-DevicePropertyData 'DEVPKEY_Device_DriverInfPath'
        Version  = Get-DevicePropertyData 'DEVPKEY_Device_DriverVersion'
        Provider = Get-DevicePropertyData 'DEVPKEY_Device_DriverProvider'
    }
}

function Test-IsRpi5FanInf([string]$InfName) {
    if ([string]::IsNullOrWhiteSpace($InfName) -or $InfName -notmatch '^oem\d+\.inf$') {
        return $false
    }

    $installedInf = Join-Path $env:windir ("INF\" + $InfName)
    if (-not (Test-Path -LiteralPath $installedInf)) {
        return $false
    }

    $text = Get-Content -LiteralPath $installedInf -Raw -ErrorAction SilentlyContinue
    return ($text -match 'ACPI\\RPI000F' -and $text -match 'RPi5 UEFI Community')
}

function Invoke-PnpDriverInstall {
    Push-Location $PackageDir
    try {
        $output = & pnputil.exe /add-driver Rpi5Fan.inf /install 2>&1
        $code = $LASTEXITCODE
        foreach ($line in $output) {
            Write-Host $line
        }
        return [pscustomobject]@{
            ExitCode = $code
            Output   = ($output -join [Environment]::NewLine)
        }
    }
    finally {
        Pop-Location
    }
}

Start-Transcript -Path $LogPath -Append | Out-Null
try {
    Write-Host 'RPi5Fan One Shot Installer v0.1.1 exp.3'
    Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "Windows: $([Environment]::OSVersion.VersionString)"
    Write-Host "Device: $DeviceId"
    Write-Host "Expected DriverVer: $ExpectedDriverVersion"
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
    if ($infText -notmatch 'DriverVer\s*=\s*08/17/2026\s*,\s*2026\.8\.17\.3') {
        throw "Unexpected driver version. Expected $ExpectedDriverVersion."
    }
    Write-Host "OK: INF hardware, architecture, and DriverVer $ExpectedDriverVersion verified."

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
        [void](Invoke-NativeAllowed bcdedit.exe @(0) /set testsigning on)
        Write-Warning 'TESTSIGNING was enabled. Reboot Windows, then run this same installer again.'
        exit 3010
    }
    Write-Host 'OK: TESTSIGNING already enabled.'

    Write-Step 'Certificate installation'
    [void](Invoke-NativeAllowed certutil.exe @(0) -addstore Root (Join-Path $PackageDir 'Rpi5Fan.cer'))
    [void](Invoke-NativeAllowed certutil.exe @(0) -addstore TrustedPublisher (Join-Path $PackageDir 'Rpi5Fan.cer'))

    Write-Step 'Current selected driver before update'
    $before = Get-SelectedDriverState
    $before | Format-List InfPath,Version,Provider

    Write-Step 'Driver installation'
    $install = Invoke-PnpDriverInstall

    if ($install.ExitCode -eq 259) {
        Write-Warning 'PnPUtil returned 259 (no better installation performed). Inspecting the driver Windows actually selected.'
        $selected = Get-SelectedDriverState
        $selected | Format-List InfPath,Version,Provider

        if ($selected.Version -eq $ExpectedDriverVersion) {
            Write-Host 'OK: The expected driver version is already selected. Continuing.'
        }
        else {
            $safeOldPackage = ($selected.Provider -eq $ExpectedProvider) -or (Test-IsRpi5FanInf $selected.InfPath)
            if (-not $safeOldPackage) {
                throw "PnPUtil returned 259 and the selected driver is not a recognized RPi5Fan package (INF=$($selected.InfPath), Version=$($selected.Version), Provider=$($selected.Provider))."
            }
            if ($selected.InfPath -notmatch '^oem\d+\.inf$') {
                throw "Recognized stale RPi5Fan driver has an unexpected INF path: $($selected.InfPath)"
            }

            Write-Step 'Replacing stale RPi5Fan package selected by Windows'
            Write-Host "Removing stale selected package $($selected.InfPath) version $($selected.Version)."
            $deleteCode = Invoke-NativeAllowed pnputil.exe @(0,3010,1641) /delete-driver $selected.InfPath /uninstall /force
            if ($deleteCode -in 3010,1641) { $RebootRequired = $true }

            [void](Invoke-NativeAllowed pnputil.exe @(0) /scan-devices)
            Start-Sleep -Seconds 1

            Write-Step 'Retry driver installation'
            $install = Invoke-PnpDriverInstall
            if ($install.ExitCode -notin 0,259,3010,1641) {
                throw "pnputil.exe retry failed with exit code $($install.ExitCode)"
            }
            if ($install.ExitCode -in 3010,1641) { $RebootRequired = $true }

            if ($install.ExitCode -eq 259) {
                $afterRetry = Get-SelectedDriverState
                $afterRetry | Format-List InfPath,Version,Provider
                if ($afterRetry.Version -ne $ExpectedDriverVersion) {
                    throw "Windows still did not select DriverVer $ExpectedDriverVersion after stale-package replacement."
                }
                Write-Host 'OK: Expected driver selected after stale-package replacement.'
            }
        }
    }
    elseif ($install.ExitCode -in 3010,1641) {
        $RebootRequired = $true
    }
    elseif ($install.ExitCode -ne 0) {
        throw "pnputil.exe failed with exit code $($install.ExitCode)"
    }

    Write-Step 'PnP rescan and restart'
    [void](Invoke-NativeAllowed pnputil.exe @(0) /scan-devices)
    & pnputil.exe /restart-device $DeviceId
    $restartCode = $LASTEXITCODE
    if ($restartCode -in 3010,1641) {
        $RebootRequired = $true
    }
    elseif ($restartCode -ne 0) {
        Write-Warning "Device restart returned exit code $restartCode; continuing with status check."
    }
    Start-Sleep -Seconds 2

    Write-Step 'Installed driver candidates'
    & pnputil.exe /enum-devices /instanceid $DeviceId /drivers

    Write-Step 'Selected driver after update'
    $finalDriver = Get-SelectedDriverState
    $finalDriver | Format-List InfPath,Version,Provider

    if ($finalDriver.Version -ne $ExpectedDriverVersion) {
        throw "Windows selected DriverVer $($finalDriver.Version) instead of expected $ExpectedDriverVersion."
    }

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
                Select-Object -Last 120 |
                ForEach-Object { $_.ToString() }
        }
        throw "Driver $ExpectedDriverVersion is selected but device is not healthy: Status=$($device.Status), Problem=$($device.Problem)"
    }

    Write-Host "`nSUCCESS: Raspberry Pi 5 Active Cooler driver v0.1.1 ($ExpectedDriverVersion) is installed and running."
    if ($RebootRequired) {
        Write-Warning 'Windows reported that a reboot is required to finalize one or more driver operations.'
    }
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

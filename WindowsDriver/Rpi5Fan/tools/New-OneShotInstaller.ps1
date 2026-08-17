#Requires -Version 5.1
param(
    [Parameter(Mandatory=$true)][string]$DriverDir,
    [Parameter(Mandatory=$true)][string]$InstallerScript,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$DriverDir = (Resolve-Path -LiteralPath $DriverDir).Path
$InstallerScript = (Resolve-Path -LiteralPath $InstallerScript).Path
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$staging = Join-Path $env:TEMP ("rpi5fan-oneshot-" + [Guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $staging 'payload.zip'
$payloadDir = Join-Path $staging 'payload'

try {
    New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
    foreach ($name in 'Rpi5Fan.inf','Rpi5Fan.sys','rpi5fan.cat','Rpi5Fan.cer') {
        $source = Join-Path $DriverDir $name
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Missing driver artifact: $source"
        }
        Copy-Item -LiteralPath $source -Destination $payloadDir
    }
    Copy-Item -LiteralPath $InstallerScript -Destination (Join-Path $payloadDir 'Install-RPi5Fan.ps1')

    Compress-Archive -Path (Join-Path $payloadDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipPath))
    $wrapped = [regex]::Matches($base64, '.{1,76}') | ForEach-Object { $_.Value }

    $stub = @'
@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1
title RPi5Fan One Shot Installer v0.1.1
set "RPI5FAN_SELF=%~f0"

if /I "%~1"=="__elevated" goto :elevated
net session >nul 2>&1
if %ERRORLEVEL% EQU 0 goto :elevated

echo Requesting Administrator privileges...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:RPI5FAN_SELF -ArgumentList '__elevated' -Verb RunAs"
exit /b

:elevated
set "RPI5FAN_TMP=%TEMP%\RPi5Fan-OneShot-%RANDOM%-%RANDOM%"
mkdir "%RPI5FAN_TMP%" >nul 2>&1

echo RPi5Fan One Shot Installer v0.1.1
echo Extracting embedded ARM64 driver package...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$lines=[IO.File]::ReadAllLines($env:RPI5FAN_SELF); $marker=-1; for($i=0;$i -lt $lines.Length;$i++){if($lines[$i].Trim() -eq '__RPI5FAN_PAYLOAD__'){$marker=$i;break}}; if($marker -lt 0 -or $marker -ge ($lines.Length-1)){throw 'Embedded payload marker not found.'}; $payloadLines=$lines[($marker+1)..($lines.Length-1)]; $b64=(($payloadLines -join '') -replace '\s',''); if([string]::IsNullOrWhiteSpace($b64)){throw 'Embedded payload is empty.'}; $zip=Join-Path $env:RPI5FAN_TMP 'payload.zip'; [IO.File]::WriteAllBytes($zip,[Convert]::FromBase64String($b64)); Expand-Archive -LiteralPath $zip -DestinationPath $env:RPI5FAN_TMP -Force; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:RPI5FAN_TMP 'Install-RPi5Fan.ps1'); exit $LASTEXITCODE"
set "RC=%ERRORLEVEL%"

rmdir /s /q "%RPI5FAN_TMP%" >nul 2>&1
echo.
if "%RC%"=="0" echo Installation finished successfully.
if not "%RC%"=="0" echo Installer exited with code %RC%.
echo Log: %USERPROFILE%\Desktop\RPi5Fan-install.log
echo.
pause
exit /b %RC%
'@

    $parent = Split-Path -Parent $OutputPath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    # Construct the marker boundary explicitly instead of relying on here-string
    # trailing-newline behavior. The extractor searches for this standalone line.
    $text = $stub.TrimEnd() + "`r`n`r`n__RPI5FAN_PAYLOAD__`r`n" + ($wrapped -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($OutputPath, $text, [Text.UTF8Encoding]::new($false))

    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath
    Write-Host "Created: $OutputPath"
    Write-Host "SHA256: $($hash.Hash)"
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

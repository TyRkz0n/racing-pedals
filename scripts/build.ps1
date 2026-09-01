<#
.SYNOPSIS
    Build the ESP32-S3 racing pedals firmware.

.EXAMPLE
    .\scripts\build.ps1
    .\scripts\build.ps1 -Clean
    .\scripts\build.ps1 -IdfPath 'C:\Espressif\frameworks\esp-idf-v5.3.1'
#>
[CmdletBinding()]
param(
    [string]$IdfPath,
    [switch]$Clean,       # remove build output, keep sdkconfig
    [switch]$Reconfigure  # also drop sdkconfig and re-run set-target
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_idf.ps1"

Initialize-Idf -IdfPath $IdfPath

$root = Get-ProjectRoot
Push-Location $root
try {
    if ($Reconfigure) {
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $root 'sdkconfig')
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $root 'build')
    } elseif ($Clean) {
        Invoke-Idf @('fullclean')
    }

    # set-target regenerates sdkconfig from sdkconfig.defaults, so only run it
    # when there is no sdkconfig yet - otherwise it would discard local menuconfig edits.
    if (-not (Test-Path (Join-Path $root 'sdkconfig'))) {
        Invoke-Idf @('set-target', 'esp32s3')
    }

    Invoke-Idf @('build')

    Write-Host ''
    Write-Host 'Build OK. Flash it with: .\scripts\flash.ps1 -Monitor' -ForegroundColor Green
} finally {
    Pop-Location
}

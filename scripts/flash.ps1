<#
.SYNOPSIS
    Build, flash and optionally monitor the racing pedals firmware.

.DESCRIPTION
    Flash over the board's COM connector (the USB-to-UART bridge). The port is
    auto-detected; -Port overrides it. -ListPorts just prints what it can see.

.EXAMPLE
    .\scripts\flash.ps1 -Monitor
    .\scripts\flash.ps1 -Port COM7
    .\scripts\flash.ps1 -ListPorts
#>
[CmdletBinding()]
param(
    [string]$Port,
    [string]$IdfPath,
    [int]$Baud = 921600,
    [switch]$Monitor,    # open the serial monitor after flashing
    [switch]$NoBuild,    # flash whatever is already in build/
    [switch]$ListPorts   # list COM ports and exit
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_idf.ps1"

if ($ListPorts) {
    $ports = @(Get-SerialPorts)
    if ($ports.Count -eq 0) {
        Write-Warning 'No COM ports found.'
    } else {
        $ports | Format-Table Port, IsBridge, IsJtag, Name -AutoSize
    }
    return
}

Initialize-Idf -IdfPath $IdfPath
$Port = Resolve-EspPort -Port $Port

$root = Get-ProjectRoot
Push-Location $root
try {
    if (-not (Test-Path (Join-Path $root 'sdkconfig'))) {
        Invoke-Idf @('set-target', 'esp32s3')
    }

    $actions = if ($NoBuild) { @('flash') } else { @('build', 'flash') }
    if ($Monitor) { $actions += 'monitor' }

    Invoke-Idf (@('-p', $Port, '-b', "$Baud") + $actions)
} finally {
    Pop-Location
}

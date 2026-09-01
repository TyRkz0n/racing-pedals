<#
.SYNOPSIS
    Open the ESP-IDF serial monitor on the board's COM port. Ctrl+] to exit.

.EXAMPLE
    .\scripts\monitor.ps1
    .\scripts\monitor.ps1 -Port COM7
#>
[CmdletBinding()]
param(
    [string]$Port,
    [string]$IdfPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_idf.ps1"

Initialize-Idf -IdfPath $IdfPath
$Port = Resolve-EspPort -Port $Port

Push-Location (Get-ProjectRoot)
try {
    Invoke-Idf @('-p', $Port, 'monitor')
} finally {
    Pop-Location
}

# Shared helpers: locate ESP-IDF, activate it, and find the board's serial ports.
# Dot-source this from build.ps1 / flash.ps1 / monitor.ps1.

function Get-ProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Find-IdfPath {
    param([string]$IdfPath)

    $candidates = @()
    if ($IdfPath)       { $candidates += $IdfPath }
    if ($env:IDF_PATH)  { $candidates += $env:IDF_PATH }

    # Standard install locations, newest version first.
    foreach ($root in @('C:\Espressif\frameworks', "$env:USERPROFILE\esp", 'C:\esp')) {
        if (Test-Path $root) {
            $candidates += Get-ChildItem -Path $root -Directory -Filter 'esp-idf*' |
                Sort-Object Name -Descending |
                ForEach-Object { $_.FullName }
        }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'export.ps1'))) { return (Resolve-Path $c).Path }
    }

    throw "ESP-IDF not found. Pass -IdfPath 'C:\path\to\esp-idf', or set `$env:IDF_PATH."
}

function Initialize-Idf {
    param([string]$IdfPath)

    $idf = Find-IdfPath -IdfPath $IdfPath

    if ($env:IDF_PATH -eq $idf -and (Get-Command idf.py -ErrorAction SilentlyContinue)) {
        Write-Host "ESP-IDF already active: $idf" -ForegroundColor DarkGray
        return
    }

    Write-Host "Activating ESP-IDF: $idf" -ForegroundColor Cyan
    $env:IDF_PATH = $idf
    . (Join-Path $idf 'export.ps1') | Out-Null

    if (-not (Get-Command idf.py -ErrorAction SilentlyContinue)) {
        throw "export.ps1 ran but idf.py is still not on PATH. Check the ESP-IDF install at $idf."
    }
}

function Get-SerialPorts {
    # Every present COM device, tagged with what kind of ESP32-S3 endpoint it is.
    $ports = @()
    foreach ($dev in (Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue)) {
        if (-not $dev.Name) { continue }
        $m = [regex]::Match($dev.Name, '\((COM\d+)\)')
        if (-not $m.Success) { continue }

        $ports += [pscustomobject]@{
            Port     = $m.Groups[1].Value
            Name     = $dev.Name
            # USB-to-UART bridge = the board's "COM" connector.
            IsBridge = ($dev.Name -match 'CP210|CH34|CH91|FT23|FTDI|Silicon Labs|USB-SERIAL|USB-Enhanced|Prolific')
            # Built-in USB Serial/JTAG = the board's "USB"/OTG connector.
            IsJtag   = ($dev.Name -match 'JTAG')
        }
    }
    return $ports | Sort-Object { [int]($_.Port -replace 'COM', '') }
}

function Resolve-EspPort {
    param([string]$Port)

    if ($Port) { return $Port }

    $ports = @(Get-SerialPorts)
    if ($ports.Count -eq 0) {
        throw "No COM ports found. Plug the board's COM (UART) port into the PC and check Device Manager for a driver."
    }

    # Prefer the UART bridge: it survives the firmware taking over the native USB
    # peripheral for HID, so auto-reset-into-download keeps working.
    $bridge = @($ports | Where-Object { $_.IsBridge })
    if ($bridge.Count -ge 1) {
        Write-Host "Using $($bridge[0].Port) - $($bridge[0].Name)" -ForegroundColor Cyan
        if ($bridge.Count -gt 1) {
            Write-Warning "More than one USB-UART bridge present; pass -Port COMx to pick a different one."
        }
        return $bridge[0].Port
    }

    $jtag = @($ports | Where-Object { $_.IsJtag })
    if ($jtag.Count -ge 1) {
        Write-Warning "Only the native USB Serial/JTAG port ($($jtag[0].Port)) was found - you are plugged into the OTG/USB connector."
        Write-Warning "It can flash, but this firmware reclaims that USB peripheral for HID, so it disappears after boot."
        Write-Warning "Use the board's COM connector for flashing instead."
        return $jtag[0].Port
    }

    Write-Warning "No recognisable ESP32-S3 port; falling back to $($ports[0].Port) - $($ports[0].Name)"
    return $ports[0].Port
}

function Invoke-Idf {
    # Note: takes a single array so callers can pass '-p'/'-b' style flags without
    # PowerShell trying to bind them as parameters of this function.
    param([Parameter(Mandatory = $true, Position = 0)][string[]]$Arguments)

    Write-Host "idf.py $($Arguments -join ' ')" -ForegroundColor DarkGray
    & idf.py @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "idf.py $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

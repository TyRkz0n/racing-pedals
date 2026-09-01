<#
.SYNOPSIS
    Show what Windows makes of the pedals' HID descriptor, then display live
    axis values so you can see which pedals actually move.

.DESCRIPTION
    Reads the HID device directly, bypassing joy.cpl. Unlike the Windows game
    controller page - which draws X and Y as a single 2D crosshair and only Z as
    its own slider - this shows all three axes as separate labelled bars.

    Needs only the USB/OTG cable; the COM port is not used.

.EXAMPLE
    .\scripts\hidtest.ps1                # 20 s live view
    .\scripts\hidtest.ps1 -Seconds 60
    .\scripts\hidtest.ps1 -Seconds 0     # descriptor info only, no live view
#>
param(
    [int]$Seconds = 20,
    [int]$VendorId  = 0x303A,
    [int]$ProductId = 0x4004
)

$cs = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class Hid
{
    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID, ProductID, VersionNumber; }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS
    {
        public ushort Usage, UsagePage;
        public ushort InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
        public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_VALUE_CAPS
    {
        public ushort UsagePage;
        public byte ReportID; public byte IsAlias;
        public ushort BitField, LinkCollection, LinkUsage, LinkUsagePage;
        public byte IsRange, IsStringRange, IsDesignatorRange, IsAbsolute, HasNull, Reserved;
        public ushort BitSize, ReportCount;
        public ushort R0, R1, R2, R3, R4;
        public uint UnitsExp, Units;
        public int LogicalMin, LogicalMax, PhysicalMin, PhysicalMax;
        public ushort Usage, U1, StringIndex, U2, DesignatorIndex, U3, DataIndex, U4;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")] public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
    [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr pp, out HIDP_CAPS caps);
    [DllImport("hid.dll")] public static extern int HidP_GetValueCaps(int reportType, [Out] HIDP_VALUE_CAPS[] caps, ref ushort len, IntPtr pp);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerator, IntPtr hwnd, int flags);
    [DllImport("setupapi.dll")]
    public static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, EntryPoint = "SetupDiGetDeviceInterfaceDetailW")]
    public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, ref int required, IntPtr devInfo);
    [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(IntPtr h, byte[] buf, int len, out int read, IntPtr ov);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    public static string[] EnumeratePaths()
    {
        Guid g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
        var list = new List<string>();
        var did = new SP_DEVICE_INTERFACE_DATA();
        did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
        for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref did); i++)
        {
            int need = 0;
            SetupDiGetDeviceInterfaceDetail(set, ref did, IntPtr.Zero, 0, ref need, IntPtr.Zero);
            if (need <= 0) continue;
            IntPtr buf = Marshal.AllocHGlobal(need);
            Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
            if (SetupDiGetDeviceInterfaceDetail(set, ref did, buf, need, ref need, IntPtr.Zero))
                list.Add(Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4)));
            Marshal.FreeHGlobal(buf);
        }
        SetupDiDestroyDeviceInfoList(set);
        return list.ToArray();
    }
}
"@

Add-Type -TypeDefinition $cs -ErrorAction Stop

$TARGET_VID = $VendorId
$TARGET_PID = $ProductId
$INVALID = New-Object IntPtr(-1)
# 0x80000000 parses as a negative Int32 in PowerShell; build it from an Int64.
$GENERIC_READ = [uint32]2147483648

$handle = $INVALID
$devPath = $null
foreach ($path in [Hid]::EnumeratePaths()) {
    $h = [Hid]::CreateFile($path, $GENERIC_READ, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h -eq $INVALID) { continue }
    $attr = New-Object Hid+HIDD_ATTRIBUTES
    $attr.Size = [System.Runtime.InteropServices.Marshal]::SizeOf($attr)
    if ([Hid]::HidD_GetAttributes($h, [ref]$attr) -and $attr.VendorID -eq $TARGET_VID -and $attr.ProductID -eq $TARGET_PID) {
        $handle = $h; $devPath = $path; break
    }
    [void][Hid]::CloseHandle($h)
}

if ($handle -eq $INVALID) {
    Write-Error ("No openable HID device with VID 0x{0:X4} PID 0x{1:X4}. Is the USB/OTG cable plugged in?" -f $TARGET_VID, $TARGET_PID)
    exit 1
}
Write-Host "Device: $devPath" -ForegroundColor Cyan

$pp = [IntPtr]::Zero
if (-not [Hid]::HidD_GetPreparsedData($handle, [ref]$pp)) { Write-Error "HidD_GetPreparsedData failed"; exit 1 }

$caps = New-Object Hid+HIDP_CAPS
[void][Hid]::HidP_GetCaps($pp, [ref]$caps)
Write-Host ""
Write-Host ("Top-level collection : UsagePage=0x{0:X2} Usage=0x{1:X2}" -f $caps.UsagePage, $caps.Usage)
Write-Host ("Input report length  : {0} bytes (incl. report ID)" -f $caps.InputReportByteLength)
Write-Host ("Input value caps     : {0}" -f $caps.NumberInputValueCaps)
Write-Host ("Input button caps    : {0}" -f $caps.NumberInputButtonCaps)

$n = [ushort]$caps.NumberInputValueCaps
if ($n -gt 0) {
    $vc = New-Object 'Hid+HIDP_VALUE_CAPS[]' $n
    $len = [ushort]$n
    $rc = [Hid]::HidP_GetValueCaps(0, $vc, [ref]$len, $pp)
    $names = @{ 48='X'; 49='Y'; 50='Z'; 51='Rx'; 52='Ry'; 53='Rz'; 54='Slider'; 57='Hat' }
    Write-Host ""
    Write-Host "AXES WINDOWS PARSED:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $len; $i++) {
        $u = $vc[$i]
        $key = [int]$u.Usage
        $nm = if ($names.ContainsKey($key)) { $names[$key] } else { "usage 0x{0:X2}" -f $key }
        Write-Host ("  {0,-7} page=0x{1:X2} reportID={2} bits={3} count={4} logical={5}..{6}" -f `
            $nm, $u.UsagePage, $u.ReportID, $u.BitSize, $u.ReportCount, $u.LogicalMin, $u.LogicalMax)
    }
}

if ($Seconds -gt 0) {
    $labels   = @('X  throttle (GPIO4)', 'Y  brake    (GPIO5)', 'Z  clutch   (GPIO6)')
    $AXIS_MAX = 32767
    $BAR      = 40

    Write-Host ""
    Write-Host "Live for $Seconds s - PRESS EACH PEDAL THROUGH ITS FULL TRAVEL. Ctrl+C to stop early." -ForegroundColor Yellow
    Write-Host ""

    $rlen = [int]$caps.InputReportByteLength
    $buf  = New-Object byte[] $rlen
    $cur  = @(0, 0, 0)
    $min  = @($AXIS_MAX, $AXIS_MAX, $AXIS_MAX)
    $max  = @(0, 0, 0)
    $count = 0

    # Reserve three lines, then repaint them in place. Cursor addressing needs a
    # real console; when redirected to a file or a CI log, skip the live view and
    # just print the summary at the end.
    $canPaint = $true
    $top = 0
    try {
        Write-Host "`n`n"
        $top = [Console]::CursorTop - 3
    } catch {
        $canPaint = $false
        Write-Host "(no interactive console - live view disabled, summary only)"
    }

    $deadline  = (Get-Date).AddSeconds($Seconds)
    $nextPaint = [datetime]::MinValue

    while ((Get-Date) -lt $deadline) {
        $read = 0
        if (-not ([Hid]::ReadFile($handle, $buf, $rlen, [ref]$read, [IntPtr]::Zero)) -or $read -lt 7) { continue }
        $count++
        for ($a = 0; $a -lt 3; $a++) {
            $v = [int]$buf[1 + $a * 2] -bor ([int]$buf[2 + $a * 2] -shl 8)
            $cur[$a] = $v
            if ($v -lt $min[$a]) { $min[$a] = $v }
            if ($v -gt $max[$a]) { $max[$a] = $v }
        }

        if (-not $canPaint) { continue }

        $now = Get-Date
        if ($now -lt $nextPaint) { continue }
        $nextPaint = $now.AddMilliseconds(50)

        try {
            for ($a = 0; $a -lt 3; $a++) {
                $fill = [int][math]::Round($BAR * [double]$cur[$a] / $AXIS_MAX)
                $bar  = ('#' * $fill).PadRight($BAR, '.')
                [Console]::SetCursorPosition(0, $top + $a)
                Write-Host ("  {0}  [{1}] {2,6}   seen {3,6}..{4,-6}" -f $labels[$a], $bar, $cur[$a], $min[$a], $max[$a]) -NoNewline
            }
        } catch {
            $canPaint = $false   # console went away mid-run; keep sampling regardless
        }
    }

    if ($canPaint) { try { [Console]::SetCursorPosition(0, $top + 3) } catch { } }
    Write-Host ""
    Write-Host "$count reports received" -ForegroundColor Cyan
    Write-Host ""
    for ($a = 0; $a -lt 3; $a++) {
        $travel = $max[$a] - $min[$a]
        if ($travel -gt ($AXIS_MAX / 2)) {
            Write-Host ("  {0}  full travel seen - OK" -f $labels[$a]) -ForegroundColor Green
        } elseif ($travel -gt 200) {
            Write-Host ("  {0}  only moved {1} of {2} - partial travel or noise" -f $labels[$a], $travel, $AXIS_MAX) -ForegroundColor Yellow
        } else {
            Write-Host ("  {0}  DID NOT MOVE (stuck at {1}) - check wiring on that GPIO" -f $labels[$a], $cur[$a]) -ForegroundColor Red
        }
    }
}

[void][Hid]::HidD_FreePreparsedData($pp)
[void][Hid]::CloseHandle($handle)

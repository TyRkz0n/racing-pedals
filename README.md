# ESP32-S3 Racing Pedals

Three analog pedals (throttle / brake / clutch) read on ADC1 and streamed to the
PC as a USB HID gamepad. Built for an **ESP32-S3-WROOM-1 N16R8** dev board with
ESP-IDF v5.3.

No drivers to install: Windows, Linux and macOS all see a standard 3-axis
joystick.

---

## Which USB port?

The board's two USB-C connectors do different jobs:

| Connector | What it is | Use it for |
|---|---|---|
| **COM / UART** | USB-to-UART bridge chip (CP2102 / CH340) | **Flashing and the serial monitor** |
| **USB / OTG** | The ESP32-S3's own USB peripheral on GPIO19/20 | **The gamepad itself** |

**Use both.** Plug the COM port into the PC to flash and watch logs, and the
USB/OTG port into the PC for the pedals to show up as a controller. Either port
alone will power the board.

Why not flash over the OTG port? It *can* flash, using the chip's built-in
USB Serial/JTAG device — but this firmware reclaims that same USB peripheral for
HID as soon as it boots, so the serial/JTAG device disappears a second after
reset. Auto-reset-into-download stops being reliable and you end up holding
BOOT + tapping RESET before every flash. The COM port has none of that problem,
which is why `flash.ps1` prefers it and warns if it only finds the JTAG port.

---

## Wiring

Each pedal is a potentiometer (or any sensor board with a 0–3.3 V analog output)
wired as a voltage divider:

```
3V3 ──────┬── pot pin 1
          │
          ├── pot wiper (pin 2) ──► GPIO
          │
GND ──────┴── pot pin 3
```

| Pedal | GPIO | ADC channel |
|---|---|---|
| Throttle | **GPIO4** | ADC1_CH3 |
| Brake | **GPIO5** | ADC1_CH4 |
| Clutch | **GPIO6** | ADC1_CH5 |

These pins were chosen because they are plain ADC1 inputs: no strapping duty
(unlike GPIO0/3/45/46), no flash/PSRAM function (GPIO26–37 on an N16R8 module),
and they leave GPIO19/20 free for the native USB D-/D+ lines. ADC2 is avoided
entirely because it is unusable whenever Wi-Fi is active.

To move a pedal to a different pin, edit the `s_cfg` table at the top of
[`main/pedals.c`](main/pedals.c) — ADC1 covers GPIO1–GPIO10 as channels 0–9.

> **3.3 V only.** Do not feed the ADC from 5 V; the ESP32-S3 inputs are not
> 5 V tolerant. If your sensor swings to 5 V, divide it down first.

---

## Build and flash

Requires ESP-IDF v5.x installed (the scripts auto-detect
`C:\Espressif\frameworks\esp-idf-*`, `%USERPROFILE%\esp\*` or `$env:IDF_PATH`).

```powershell
# Build only
.\scripts\build.ps1

# Build, flash over the auto-detected COM port, then open the monitor
.\scripts\flash.ps1 -Monitor

# See which COM ports are visible and what they are
.\scripts\flash.ps1 -ListPorts

# Pin things down explicitly
.\scripts\flash.ps1 -Port COM7 -Baud 460800
.\scripts\build.ps1 -IdfPath 'C:\Espressif\frameworks\esp-idf-v5.3.1'

# Serial monitor on its own (Ctrl+] to exit)
.\scripts\monitor.ps1

# Live per-axis view of what the PC is actually receiving (USB/OTG cable only)
.\scripts\hidtest.ps1
```

Other switches: `build.ps1 -Clean` (idf.py fullclean),
`build.ps1 -Reconfigure` (also discard `sdkconfig` and re-run `set-target`),
`flash.ps1 -NoBuild` (flash whatever is already in `build/`).

If PowerShell blocks the scripts, allow them for the session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

---

## Calibration

Auto-ranging is **on** by default (`PEDAL_AUTO_RANGE` in
[`main/pedals.h`](main/pedals.h)). Each pedal starts with an unknown range and
learns it from the movement it sees, so:

**After every power-up, press each pedal once through its full travel.** The
axis then spans the whole range. Until a pedal has been swept it reports 0, so a
freshly reset board looks like it has three dead pedals — it does not.

The learned range only ever widens, never shrinks, so if a pin was left floating
(or a pot was faulty) while the board was running, its range was learned from
noise. Reset the board after fixing the wiring to throw that away, then sweep.

To make it permanent instead, watch the `raw=` values in the serial monitor at
rest and fully pressed, put those numbers into the `raw_min` / `raw_max` fields
of the `s_cfg` table in `main/pedals.c`, and set `PEDAL_AUTO_RANGE` to `0`.

Other knobs in `main/pedals.h`:

| Setting | Default | Effect |
|---|---|---|
| `PEDAL_OVERSAMPLE` | 8 | ADC samples averaged per reading |
| `PEDAL_EMA_ALPHA` | 0.25 | Smoothing; lower = smoother but laggier |
| `PEDAL_DEADZONE_LO/HI` | 655 (2 %) | Travel ignored at each end, then rescaled |

Set `invert = true` for a pedal whose voltage *falls* as you press it.

---

## Testing it

```powershell
.\scripts\hidtest.ps1
```

This reads the HID device directly and draws all three axes as separate live
bars, with a per-axis verdict at the end. It only needs the USB/OTG cable.
Prefer it over `joy.cpl` for diagnosis — see the warning below.

Other options:

- **Linux:** `jstest /dev/input/js0`, or `evtest`.
- **Anywhere:** <https://hardwaretester.com/gamepad> in a browser — shows every
  axis as its own labelled bar.
- **Serial monitor:** `.\scripts\monitor.ps1` prints one line per second with
  raw ADC counts, scaled axis values, and whether the host has enumerated the
  device. This is the only view that shows the *raw ADC* side, so it is what
  tells you whether a problem is wiring or firmware.

### Why `joy.cpl` looks like it is missing axes

The Windows "Set up USB game controllers" test page does **not** draw one bar
per axis. It draws:

- **X and Y together as a single 2D crosshair** — throttle moves the dot
  sideways, brake moves it up and down.
- **Z as the only separate slider** — the clutch.

So three working pedals look like "one square and one slider", not three bars.
If you are checking whether all three pedals work, use `hidtest.ps1` or
hardwaretester.com instead; `joy.cpl` is genuinely misleading here.

If you would rather each pedal got its own labelled slider in `joy.cpl`, change
the three usages in the report descriptor in `main/usb_hid.c` from X/Y/Z
(`0x09,0x30` / `0x31` / `0x32`) to, for example, Z/Rz/Slider
(`0x09,0x32` / `0x35` / `0x36`). Games bind to whatever they are given, so this
is purely a question of how Windows displays it.

---

## How it works

| File | Role |
|---|---|
| `main/main.c` | 500 Hz sample-and-report loop |
| `main/pedals.c/.h` | ADC1 setup, oversampling, EMA filter, ranging, scaling |
| `main/usb_hid.c/.h` | HID report descriptor, USB descriptors, TinyUSB setup |

The HID report is three **16-bit** axes (0–32767) plus 8 buttons:

```c
typedef struct __attribute__((packed)) {
    uint16_t axis[3];   // X = throttle, Y = brake, Z = clutch
    uint8_t  buttons;   // always 0 today
} pedal_hid_report_t;
```

16-bit axes rather than TinyUSB's stock 8-bit `TUD_HID_REPORT_DESC_GAMEPAD`
because 256 steps of brake travel is coarse enough to feel as stepping. The
buttons are always zero — they are declared because some games and calibration
UIs ignore a controller with no buttons at all, and they give you somewhere to
put real switches later (just set `report.buttons`).

The USB endpoint is polled at 1 kHz; the firmware samples at 500 Hz and sends a
report only when an axis actually moves (plus a keepalive every 100 ms).

Device identifies as VID `0x303A` / PID `0x4004` (Espressif's TinyUSB HID
example IDs) with a serial number derived from the chip's MAC, so two boards on
one PC stay distinguishable. Change them in `main/usb_hid.c` if you need to.

---

## Notes on the N16R8

`sdkconfig.defaults` sets 16 MB flash, DIO @ 80 MHz, single large app
partition. The 8 MB of octal PSRAM is **not** enabled — this firmware does not
need it. To turn it on: `CONFIG_SPIRAM=y` and `CONFIG_SPIRAM_MODE_OCT=y`.

## Troubleshooting

- **Nothing in `joy.cpl`** — check you plugged the *USB/OTG* connector in, not
  just COM. The serial log prints `usb=mounted` once the host enumerates it.
- **Axis sitting at 0** — ambiguous, and *usually fine*. Auto-ranging reports 0
  until it has seen that pedal move, so an untouched working pedal looks exactly
  like a dead one. Sweep it and look again before suspecting the wiring.
- **Axis frozen at some non-zero value** — that GPIO has a fixed voltage on it:
  wiper not connected, or the pot's ends have no 3V3/GND. `hidtest.ps1` names
  the axis and its GPIO.
- **Axis swings wildly on its own** — the pin is floating, i.e. nothing is
  connected. An unwired ADC pin picks up noise, and auto-ranging then stretches
  that noise across the full axis, so it looks like a very twitchy pedal.
- **Axis moves backwards** — set `invert = true` for that pedal in `s_cfg`.
- **Jittery axis** — lower `PEDAL_EMA_ALPHA`, raise `PEDAL_OVERSAMPLE`, and make
  sure the pot's ground returns to the board's GND.
- **Flash fails / no COM port** — install the CP2102 or CH340 driver, then
  `.\scripts\flash.ps1 -ListPorts`. As a last resort, hold BOOT, tap RESET,
  release BOOT, and flash.

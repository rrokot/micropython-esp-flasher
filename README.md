# esp32-mp-flasher

Installs MicroPython on a connected ESP32 board, or updates it to the latest
stable release, on its own. No arguments, no configuration, nothing to install:
it is a Windows PowerShell script plus Espressif's standalone `esptool.exe`.

![The flasher has found an ESP32-S3 running MicroPython 1.28.0, picked the octal-PSRAM build and counts down to updating it to 1.29.0](docs/screen.svg)

## Download

Get `esp32-mp-flasher-vX.Y.Z.zip` from the
[latest release](https://github.com/rrokot/esp32-mp-flasher/releases/latest),
unpack it anywhere and double-click `esp32-mp-flasher.cmd`. The zip already
contains `esptool.exe`, so only the firmware itself needs the internet.

## Usage

Double-click `esp32-mp-flasher.cmd`, or:

```
powershell -ExecutionPolicy Bypass -File esp32-mp-flasher.ps1
```

It runs on the Windows PowerShell 5.1 that ships with Windows 10 and 11, and on
PowerShell 7. Without a bundled `esptool.exe`, as in a clone of this repository,
the first run downloads the latest one from
[espressif/esptool releases](https://github.com/espressif/esptool/releases) into
the `esptool` folder next to the script. To update esptool, delete that folder.

It finds every board plugged in, identifies each chip, works out which build
belongs on it and looks up the latest stable release on micropython.org. Then
it takes the boards one after another, each with its plan and a 5-second
countdown, as in the picture above:

- **No MicroPython, or an older version** (a preview of the same release counts
  as older): the countdown ends in flashing.
- **Already the latest, or newer**: the countdown ends in skipping the board;
  nothing is written.

Any key or click during a countdown opens the menu for that board instead.
A board that fails does not stop the rest. With more than one board, a summary
at the end lists what happened to each.

The menu offers `flash`, `erase + flash`, `other build` and `skip`. It works
with the arrows or the mouse wheel, by hovering and clicking, or by pressing
the row's key; keys act on a single press and work on any keyboard layout.
`flash`, which is also what the countdown runs, leaves the filesystem partition
alone, so `boot.py` and the rest of the device files survive. `erase + flash`
wipes the whole chip, including the filesystem, and asks again first.
`other build` lists the available variants in case the guess is wrong. While
esptool works, a progress bar replaces its output; if it fails, the tail of
that output is shown with the error.

Ports are never asked for. Every flashable port is probed, in order: a board
held in download mode, then USB-Serial/JTAG, then USB-UART bridges (Silicon
Labs, WCH, FTDI, Prolific). A port where no ESP32 answers is noted and passed
over. Adapters with any other USB vendor are listed but not probed: ESP32
boards do not use them, and probing toggles DTR/RTS, which resets an Arduino,
and types into the port. A board plugged in through both its UART and its native USB
connector shows up on two ports; the chip's MAC address gives it away, and it
is flashed once, through the port it answered on first. JTAG is probed before
the bridges because probing through a bridge resets the chip, and with it the
board's JTAG port, while probing through JTAG leaves the bridge alone. A board
that should be left alone has to be unplugged, or skipped during its countdown.

## How the variant is chosen

1. The live REPL banner (`os.uname().machine`) — authoritative when the board
   already runs MicroPython.
2. eFuse PSRAM capacity from `esptool flash-id`. On ESP32-S3, 8 MB or more of
   embedded PSRAM means octal (`SPIRAM_OCT`), 2 MB means quad. Matches Espressif
   module suffixes: R8/R16 octal, R2 quad.
3. Whatever `v` picks, if both of the above got it wrong.

The same order yields `SPIRAM` for classic ESP32 modules.

## Flash offset

Taken per chip from esptool's `CHIP_DEFS[chip].BOOTLOADER_FLASH_OFFSET`, because
it is not uniform: ESP32 and S2 use `0x1000`, S3/C3/C6 use `0x0`, C5 and P4 use
`0x2000`. The standalone `esptool.exe` cannot be queried for it, so the values
are copied into the `$BootloaderOffsets` table in `esp32-mp-flasher.ps1`.

## Baud rates

Starts at 2000000 and falls back through 921600, 460800 and 115200 until one
sticks. CP2102N usually sustains 2M, CH340 tops out around 921600. Boards on
native USB CDC ignore the setting entirely.

The link is not the bottleneck. Measured on an ESP32-S3, an 8 MB image took
11.3 s over a 2 Mbaud UART bridge and 11.4 s over native USB-Serial/JTAG, whose
raw bandwidth is several times higher. Both land near 100 kB/s, so the wall is
the stub's per-block round-trips plus erase and program time on the SPI flash.
Raising the baud rate or switching transport buys nothing.

## Ports

Only some serial ports can be flashed. `303a:4001` is the CDC port published by
the running firmware: it carries the REPL and disappears the moment the chip
resets, so esptool cannot use it. `303a:1001` (USB-Serial/JTAG) is a separate
hardware block that survives resets, and any USB-UART bridge works as well.
Unflashable ports are skipped with a note.

After flashing, the board usually comes back on a different port than the one it
was flashed through, because the ROM interface hands over to the firmware's own
CDC. The script waits for whichever port appears and reads the banner there.

## Offline use

Every downloaded build is kept in the `firmware` folder next to
`esp32-mp-flasher.ps1` and is not downloaded again. This folder travels with
the script, and its location does not depend on the user profile or working
directory. When micropython.org cannot be reached, the script says so and
treats the newest stable release in that folder, per variant, as the latest:
the same rules then decide whether to flash. If the guessed variant is
unavailable, it selects the only available variant or asks you to choose.

Before going offline, run the script once while online: that fetches
`esptool.exe` and caches the board's firmware. Repeat for any other board or
variant you need. Then copy the whole folder, including `esptool` and `firmware`,
to the offline computer; nothing else needs to be installed there.
Alternatively, put `esptool.exe` from the release zip into the `esptool` folder
by hand and copy official stable `.bin` files into the `firmware` folder,
keeping their original filenames.

If no matching firmware is cached, the script stops with instructions to
connect to the internet or add a firmware file. Incomplete downloads are saved
as `.bin.part` and are never offered for flashing.

## Notes

Firmware is cached in `firmware/` next to the script. Preview builds are ignored; only
tagged stable releases are offered.

Tests need no framework: `powershell -ExecutionPolicy Bypass -File esp32-mp-flasher.Tests.ps1`.
`bench.cmd` times erase and write at several baud rates over a UART bridge and
saves the table to `bench.txt`; it erases the whole chip.

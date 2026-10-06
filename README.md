# mpflash

Flashes a stable MicroPython build onto a connected ESP32 board.
Uses local firmware first; checks online when no local build exists or when requested.
No arguments, no configuration.

## Usage

For the initial setup, install Python and `uv`, then run `uv sync` while online.
After that, double-click `mpflash.cmd`, or:

```
uv run --offline --no-sync mpflash.py
```

It finds the board, identifies the chip, works out which build belongs on it,
prints what it is about to do and waits:

```
port     COM5
chip     ESP32-S3
flash    8MB
psram    8MB
board    ESP32_GENERIC_S3-SPIRAM_OCT
offset   0x0
current  1.28.0
target   1.29.0

[enter] flash   e = erase and flash   v = other variant   u = check updates   q = quit:
```

`e` wipes the whole chip, including the filesystem. Plain `enter` leaves the
filesystem partition alone, so `boot.py` and the rest of the device files
survive. `v` lists the available variants in case the guess is wrong.
`u` checks the website for the latest stable releases before you confirm flashing.

With more than one board plugged in it prints a numbered list and asks which.

## How the variant is chosen

1. The live REPL banner (`os.uname().machine`) — authoritative when the board
   already runs MicroPython.
2. eFuse PSRAM capacity from `esptool flash-id`. On ESP32-S3, 8 MB or more of
   embedded PSRAM means octal (`SPIRAM_OCT`), 2 MB means quad. Matches Espressif
   module suffixes: R8/R16 octal, R2 quad.
3. Whatever `v` picks, if both of the above got it wrong.

The same order yields `SPIRAM` for classic ESP32 modules.

## Flash offset

Read from esptool itself (`CHIP_DEFS[chip].BOOTLOADER_FLASH_OFFSET`) rather than
hardcoded, because it is not uniform: ESP32 and S2 use `0x1000`, S3/C3/C6 use
`0x0`, C5 and P4 use `0x2000`.

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

The script first looks in the `firmware` folder next to `mpflash.py`. If matching
files exist, it uses the newest local stable release for each available variant
without making any network requests. This folder travels with the script,
and its location does not depend on the user profile or working directory.
If the guessed variant is unavailable, it selects the only available variant
or asks you to choose. Press `u` to check for online updates; if the site is
unreachable, it keeps using local firmware.

`mpflash.cmd` uses the existing `.venv` directly, so normal launches do not ask
`uv` to resolve or download dependencies. If there is no `.venv`, it tries
`uv run --offline` using already cached packages. On a new computer, prepare
Python and the dependencies with `uv sync` while online; copying `.bin` files
alone does not install the runtime.

Before going offline, install the dependencies with `uv sync`, then flash the
board once to cache its firmware. Repeat for any other board
or variant you need. Alternatively, copy official stable `.bin` files into the
`firmware` folder, keeping their original filenames. Python, `uv`, and the project
dependencies must already be installed on the offline computer.

If no matching firmware is cached, the script stops with instructions to
connect to the internet or add a firmware file. Incomplete downloads are saved
as `.bin.part` and are never offered for flashing.

## Notes

Firmware is cached in `firmware/` next to the script. Preview builds are ignored; only
tagged stable releases are offered.

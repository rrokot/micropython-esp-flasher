# micropython-esp-flasher

Installs MicroPython on every connected ESP board, or updates it to the latest
stable release. Nothing to configure or install: a Windows PowerShell script
plus Espressif's `esptool.exe`.

![The flasher has found an ESP32-S3 running MicroPython 1.28.0 and counts down to updating it to 1.29.0](docs/screen.svg)

## Usage

Download the zip from the
[latest release](https://github.com/rrokot/micropython-esp-flasher/releases/latest),
unpack it and double-click `micropython-esp-flasher.cmd`. Works on Windows 10 and 11.

For each board it finds, it picks the matching build and counts down 5 seconds:

- no MicroPython or an older version: flashes it, keeping the files on the board;
- already the latest: leaves it alone.

Press any key or click during the countdown for a menu: `flash`,
`erase + flash` (wipes the files too), `other build`, `skip`. Arrows, mouse or
the row's key all work.

Ports are found on their own. Serial adapters that ESP boards don't use (an
Arduino, say) are not touched; they are offered at the end in case one is
an ESP board after all.

## Offline

Downloaded firmware is kept in the `firmware` folder and reused. Without
internet, the newest build there counts as the latest. To prepare an offline
computer, run the flasher once online for each kind of board, then copy the
whole folder.

## Development

Tests: `powershell -ExecutionPolicy Bypass -File micropython-esp-flasher.Tests.ps1`.
A clone has no `esptool.exe`; the first run downloads it. `bench.cmd` times
flashing at several baud rates and erases the chip.

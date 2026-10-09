# micropython-esp-flasher

Install or update MicroPython on ESP32 boards from Windows, Linux, or macOS.

![MicroPython update countdown](docs/screen.svg)

## Features

The tool can:

- Find USB serial ports and update several ESP32 boards in one run.
- Select firmware from chip type, flash size, and PSRAM.
- Skip boards that need no update, including boards with a newer MicroPython version.
- Replace a recognised wrong build with the correct build of the same version.
- Ask for confirmation if it detects that a firmware change would lose files.
- Use downloaded firmware without an internet connection.

## Usage

1. Download the archive for your system from the [latest release](https://github.com/rrokot/micropython-esp-flasher/releases/latest).
2. Extract the archive.
3. Connect your boards to the computer.
4. On Windows, double-click `micropython-esp-flasher.exe`. On Linux or macOS, open a terminal in the tool folder and run `./micropython-esp-flasher`.

Builds are available for Windows x64, Linux x64 and ARM64, and macOS Intel and Apple Silicon.
Linux needs glibc 2.35 or later, `libudev.so.1`, and access to the serial port.
On Ubuntu or Debian, add your account to the `dialout` group, then log out and log in again.

The tool waits 5 seconds before it writes firmware or skips a board.
Press a key or click during this time to open the menu.
Select `flash`, `erase + flash`, `other build`, or `skip`.
`erase + flash` deletes all files on the board.

To report a problem, include the log file from the `logs` folder.

## Offline

The tool stores firmware in the `firmware` folder.
For offline use:

1. With the computer online, install each required firmware build on a board.
2. Copy the complete tool folder to the offline computer.

# Rust development

The `rust` branch builds a native application with the espflash library.
The PowerShell version remains on `master`.

## Build and test

Install Rust 1.99 or later and the native C build tools for your Rust target.
On Windows, the standard MSVC toolchain needs Visual Studio C++ Build Tools.
The GNU toolchain can use MinGW-w64.
On Ubuntu or Debian, install `build-essential`, `pkg-config`, and `libudev-dev`.
On macOS, install the Xcode Command Line Tools.

```text
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --locked
cargo build --release --locked
```

The executable is in `target/release`.
By default, firmware and logs are stored next to the executable.
During development, use `--data-dir .` to use the project folders.

## Platforms

GitHub Actions builds and tests Windows x64, Linux x64 and ARM64, and macOS x64 and ARM64.
Each build uses a native runner. Rust dependencies and the license tool are cached between runs.
The Linux builds use Ubuntu 22.04 and need glibc 2.35 or later and `libudev.so.1`.
The macOS builds use macOS 15. The program runs in a terminal.

On Linux, give your account access to the serial port. On Ubuntu or Debian, run
`sudo usermod -aG dialout "$USER"`, then log out and log in again.
Other distributions can use a different serial port group.
Use `/dev/ttyUSB0` or `/dev/ttyACM0` in place of `COM5` in the commands below.
On macOS, use the board's `/dev/cu.*` port.

Flashing a connected board has been tested on Windows.
Linux and macOS CI checks cover compilation, automated tests, and the packaged executable.
They do not test a connected board.

## Commands

With no command, the program detects known USB serial adapters and opens the normal interactive flow.
Unknown adapters are offered for manual selection.
ESP8266 is not supported.

```text
micropython-esp-flasher --port COM5 --data-dir . probe
micropython-esp-flasher --port COM5 --data-dir . plan
micropython-esp-flasher --port COM5 --data-dir . --offline plan
micropython-esp-flasher --port COM5 backup --output backups/board.bin
micropython-esp-flasher --port COM5 --data-dir . --yes flash --force
micropython-esp-flasher --port COM5 --data-dir . flash --variant SPIRAM_OCT
```

`probe` reads board information and prints JSON. `plan` also checks the firmware catalog.
Both commands can reset the board. Neither command writes firmware.
`--port` can contain several ports, separated by commas.
`--yes` accepts normal flash or skip actions without a menu.
It does not permit an implicit erase when a firmware change would lose files.
`flash --erase` explicitly selects a full-chip erase.
`--no-pause` closes the application without waiting for a key.

## Hardware test

The ignored hardware test needs a board that already runs MicroPython.
The cache must contain the same stable version and a build with the same filesystem location.
The test saves a full flash backup in `backups`, creates a temporary board file,
reflashes without erasing the chip, and compares SHA-256 hashes of all board files.
It then removes its temporary file and checks the original file list and hashes again.

Run the test only on the port you intend to reflash:

```powershell
$env:MPFLASH_HARDWARE_TEST = '1'
$env:MPFLASH_TEST_PORT = 'COM5'
$env:MPFLASH_DATA_DIR = (Get-Location).Path
cargo test hardware_reflash_preserves_all_files -- --ignored --nocapture --test-threads=1
```

## Firmware selection

The program selects generic builds from micropython.org.
It uses chip identity, flash size, embedded PSRAM and memory reported by MicroPython.
It also identifies the D2WD, PICO-V3-02 and single-core ESP32 variants.
When online, it passes over variants that are not built for the latest stable version.

A detected wrong build is replaced automatically only if the installed version is not newer.
The partition table in the selected image determines the flash offset and filesystem location.
An invalid image, a chip mismatch or an image that overlaps the filesystem prevents writing.
An error after reaching the MicroPython REPL prevents automatic flashing.

## Packaging

The workflow uploads a ZIP for Windows and a `tar.gz` for Linux and macOS.
Each archive contains the executable, README, illustration, project license and dependency license notices.
Each artifact also contains a SHA-256 checksum file.
CI extracts each archive and runs the executable to check the package and its file permissions.
The artifact is a development build; it does not replace the current GitHub release.

import http.client
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import serial
from serial.tools import list_ports

BASE = "https://micropython.org"
BAUDS = [2000000, 921600, 460800, 115200]
CACHE = Path(__file__).resolve().parent / "firmware"

BOARDS = {
    "ESP32": "ESP32_GENERIC",
    "ESP32-S2": "ESP32_GENERIC_S2",
    "ESP32-S3": "ESP32_GENERIC_S3",
    "ESP32-C2": "ESP32_GENERIC_C2",
    "ESP32-C3": "ESP32_GENERIC_C3",
    "ESP32-C5": "ESP32_GENERIC_C5",
    "ESP32-C6": "ESP32_GENERIC_C6",
    "ESP32-H2": "ESP32_GENERIC_H2",
    "ESP32-P4": "ESP32_GENERIC_P4",
}

FAMILY_RE = re.compile(r"^ESP32-(S2|S3|C2|C3|C5|C6|H2|P4)\b")

KNOWN_DEVICES = {
    (0x303A, 0x1001): ("ESP32 USB-Serial/JTAG", True),
    (0x303A, 0x0002): ("ESP32-S2 ROM download mode", True),
    (0x303A, 0x0009): ("ESP32-S3 ROM download mode", True),
    (0x303A, 0x4001): ("firmware USB CDC, REPL only", False),
}

KNOWN_VENDORS = {
    0x0403: "FTDI bridge",
    0x067B: "Prolific bridge",
    0x10C4: "Silicon Labs bridge",
    0x1A86: "WCH bridge",
}


def esptool(port, *args, baud=None):
    cmd = [sys.executable, "-m", "esptool", "--port", port]
    if baud:
        cmd += ["--baud", str(baud)]
    cmd += list(args)
    env = os.environ | {"COLUMNS": "200", "NO_COLOR": "1", "TERM": "dumb"}
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def chip_arg(chip):
    return chip.lower().replace("-", "")


def bootloader_offset(chip):
    from esptool.targets import CHIP_DEFS

    return CHIP_DEFS[chip_arg(chip)].BOOTLOADER_FLASH_OFFSET


def normalize_chip(name):
    m = FAMILY_RE.match(name)
    return f"ESP32-{m.group(1)}" if m else "ESP32"


def ask(prompt, options):
    while True:
        answer = input(prompt).strip().lower()
        if answer in options:
            return answer


def choose(items, label):
    if not items:
        sys.exit(f"no {label} found")
    if len(items) == 1:
        return items[0]
    for i, item in enumerate(items, 1):
        print(f"  {i}. {item}")
    while True:
        raw = input(f"{label} [1-{len(items)}]: ").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(items):
            return items[int(raw) - 1]


def classify(p):
    known = KNOWN_DEVICES.get((p.vid, p.pid))
    if known:
        return known
    vendor = KNOWN_VENDORS.get(p.vid)
    return (vendor, True) if vendor else ("unknown adapter", True)


def choose_port():
    ports = [p for p in list_ports.comports() if p.vid]
    if not ports:
        sys.exit("no board detected, plug one in")

    usable, skipped = [], []
    for p in ports:
        label, flashable = classify(p)
        (usable if flashable else skipped).append((p.device, label))
    for device, label in skipped:
        print(f"skipping {device} ({label})")

    if not usable:
        sys.exit(
            "no port that can be flashed\n"
            "this board exposes only its firmware serial port\n"
            "hold BOOT, tap RESET, release BOOT and run again"
        )
    if len(usable) == 1:
        return usable[0][0]
    print("several boards connected:")
    labels = [f"{device}  {label}" for device, label in usable]
    return choose(labels, "port").split()[0]


def port_info(port):
    for p in list_ports.comports():
        if p.device == port:
            ids = f"{p.vid:04x}:{p.pid:04x}" if p.vid else "?"
            return f"{classify(p)[0]} [{ids}]"
    return "?"


def port_snapshot():
    return {p.device for p in list_ports.comports() if p.vid}


def wait_for_board(before, previous, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        now = port_snapshot()
        appeared = now - before
        if appeared:
            time.sleep(1.0)
            return sorted(appeared)[0]
        if previous in now:
            return previous
        time.sleep(0.5)
    return previous


def probe_repl(port):
    try:
        with serial.Serial(port, 115200, timeout=0.4) as s:
            s.write(b"\x03\x03\x02\r\n")
            time.sleep(0.3)
            s.reset_input_buffer()
            s.write(b"import os\rprint(os.uname().machine)\r")
            time.sleep(0.6)
            return s.read(4096).decode("utf-8", "replace")
    except Exception:
        return ""


def detect_chip(port):
    for attempt in range(2):
        r = esptool(port, "flash-id")
        out = r.stdout + r.stderr
        m = re.search(r"Chip (?:is|type:)\s*(ESP32\S*)", out)
        if m:
            break
        if attempt == 0:
            print("no answer, retrying")
            time.sleep(1.5)
    if not m:
        print(out)
        sys.exit("could not identify the chip, see esptool output above")
    psram = re.search(r"Embedded PSRAM (\d+)MB", out)
    flash = re.search(r"Detected flash size:\s*(\S+)", out)
    return (
        normalize_chip(m.group(1)),
        int(psram.group(1)) if psram else 0,
        flash.group(1) if flash else "?",
    )


NETWORK_ERRORS = (OSError, urllib.error.URLError, http.client.HTTPException)


def parse_builds(board, names):
    pattern = re.compile(
        re.escape(board) + r"-(?:([A-Z0-9_]+)-)?(\d{8})-v(\d+)\.(\d+)(?:\.(\d+))?\.bin$"
    )
    builds = {}
    for name in names:
        m = pattern.fullmatch(name)
        if not m:
            continue
        variant = m.group(1)
        version = (int(m.group(3)), int(m.group(4)), int(m.group(5) or 0))
        key = version + (m.group(2),)
        if variant not in builds or key > builds[variant][0]:
            label = ".".join(str(n) for n in version)
            builds[variant] = (key, f"{BASE}/resources/firmware/{name}", name, label)
    return builds


def cached_builds(board):
    names = (p.name for p in CACHE.glob("*.bin") if p.is_file() and p.stat().st_size)
    return parse_builds(board, names)


def fetch_builds(board, *, check_online=False):
    if not check_online:
        builds = cached_builds(board)
        if builds:
            print(f"using local firmware from {CACHE}")
            print("press u at the prompt to check for online updates")
            return builds
    try:
        with urllib.request.urlopen(f"{BASE}/download/{board}/", timeout=10) as response:
            html = response.read().decode()
    except NETWORK_ERRORS:
        builds = cached_builds(board)
        if not builds:
            sys.exit(
                f"cannot reach micropython.org and no cached firmware for {board}\n"
                f"connect to the internet and flash once, or copy a stable {board} .bin to {CACHE}"
            )
        print(f"offline: using cached firmware from {CACHE}")
        print("the latest online release cannot be checked")
        return builds
    names = (link.rsplit("/", 1)[1] for link in re.findall(r"/resources/firmware/[^\"]+\.bin", html))
    builds = parse_builds(board, names)
    if not builds:
        sys.exit(f"no firmware published for {board}")
    return builds


def guess_variant(chip, banner, psram_mb, builds):
    if "Octal-SPIRAM" in banner and "SPIRAM_OCT" in builds:
        return "SPIRAM_OCT"
    if chip == "ESP32-S3":
        return "SPIRAM_OCT" if psram_mb >= 8 and "SPIRAM_OCT" in builds else None
    if chip == "ESP32" and ("SPIRAM" in banner or psram_mb) and "SPIRAM" in builds:
        return "SPIRAM"
    return None


def download(url, name):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / name
    if not path.is_file() or not path.stat().st_size:
        print(f"downloading {name}")
        partial = path.with_suffix(".bin.part")
        try:
            with urllib.request.urlopen(url, timeout=10) as response, partial.open("wb") as output:
                expected_size = response.headers.get("Content-Length")
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            size = partial.stat().st_size
            if not size:
                raise OSError("empty firmware download")
            if expected_size is not None and size != int(expected_size):
                raise OSError("incomplete firmware download")
            partial.replace(path)
        finally:
            partial.unlink(missing_ok=True)
    return path


def flash(port, chip, path, erase):
    if erase:
        print("erasing flash")
        r = esptool(port, "--chip", chip_arg(chip), "erase-flash")
        print(r.stdout or r.stderr)
        if r.returncode:
            sys.exit("erase failed")
    offset = bootloader_offset(chip)
    for baud in BAUDS:
        print(f"writing at {baud} baud")
        r = esptool(
            port,
            "--chip",
            chip_arg(chip),
            "write-flash",
            hex(offset),
            str(path),
            baud=baud,
        )
        print(r.stdout or r.stderr)
        if r.returncode == 0:
            return baud
        print(f"{baud} baud failed, dropping down")
    sys.exit("flashing failed at every baud rate")


def main():
    if not sys.stdin.isatty():
        sys.exit("run this from a console")

    port = choose_port()
    print(f"port     {port}")
    print(f"adapter  {port_info(port)}")

    print("reading repl banner")
    banner = probe_repl(port)
    time.sleep(0.5)
    print("identifying chip")
    chip, psram_mb, flash_size = detect_chip(port)
    board = BOARDS.get(chip)
    if not board:
        sys.exit(f"unsupported chip: {chip}")

    builds = fetch_builds(board)
    variant = guess_variant(chip, banner, psram_mb, builds)
    if variant not in builds:
        names = [v or "(base)" for v in sorted(builds, key=lambda v: v or "")]
        print("the guessed variant is unavailable; choose from available firmware:")
        chosen = choose(names, "variant")
        variant = None if chosen == "(base)" else chosen
    current = re.search(r"MicroPython v(\S+)", banner)

    while True:
        _, url, name, version = builds[variant]
        print(f"chip     {chip}")
        print(f"flash    {flash_size}")
        print(f"psram    {str(psram_mb) + 'MB' if psram_mb else 'none'}")
        print(f"board    {board}" + (f"-{variant}" if variant else ""))
        print(f"offset   {hex(bootloader_offset(chip))}")
        print(f"current  {current.group(1) if current else 'unknown'}")
        print(f"target   {version}")
        print()
        answer = ask(
            "[enter] flash   e = erase and flash   v = other variant   u = check updates   q = quit: ",
            {"", "e", "v", "u", "q"},
        )
        if answer == "q":
            return
        if answer == "u":
            builds = fetch_builds(board, check_online=True)
            if variant not in builds:
                names = [v or "(base)" for v in sorted(builds, key=lambda v: v or "")]
                chosen = choose(names, "variant")
                variant = None if chosen == "(base)" else chosen
            print()
            continue
        if answer != "v":
            break
        names = [v or "(base)" for v in sorted(builds, key=lambda v: v or "")]
        chosen = choose(names, "variant")
        variant = None if chosen == "(base)" else chosen
        print()

    path = download(url, name)
    before = port_snapshot()
    baud = flash(port, chip, path, answer == "e")
    time.sleep(2)
    port = wait_for_board(before, port)
    print(f"board is back on {port}")
    after = probe_repl(port)
    m = re.search(r"MicroPython v\S+.*", after)
    print(f"\ndone at {baud} baud")
    print(m.group(0) if m else after.strip() or "no banner, power-cycle the board")


if __name__ == "__main__":
    status = 0
    try:
        main()
    except KeyboardInterrupt:
        status = 1
    except SystemExit as e:
        if e.code not in (0, None):
            print(f"\n{e.code}")
            status = 1
    except Exception:
        import traceback

        traceback.print_exc()
        status = 1
    if sys.stdin.isatty():
        input("\npress enter to close ")
    raise SystemExit(status)

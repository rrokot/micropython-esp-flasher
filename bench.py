import re
import time
from pathlib import Path

from serial.tools import list_ports

from mpflash import CACHE, chip_arg, detect_chip, esptool

RESULTS = Path(__file__).with_name("bench.txt")


def bridge_port():
    ports = [p for p in list_ports.comports() if p.vid and p.vid != 0x303A]
    if not ports:
        raise SystemExit("no usb-uart bridge found, plug the uart cable in")
    if len(ports) > 1:
        for i, p in enumerate(ports, 1):
            print(f"  {i}. {p.device}  {p.description}")
        while True:
            raw = input(f"port [1-{len(ports)}]: ").strip()
            if raw.isdigit() and 1 <= int(raw) <= len(ports):
                return ports[int(raw) - 1].device
    return ports[0].device


def firmware():
    bins = sorted(CACHE.glob("*.bin"), key=lambda p: p.stat().st_mtime)
    if not bins:
        raise SystemExit("no cached firmware, run mpflash.py once first")
    return bins[-1]


def measure(port, chip, label, args, baud):
    print(f"\n=== {label} ===")
    start = time.monotonic()
    r = esptool(port, "--chip", chip_arg(chip), *args, baud=baud)
    elapsed = time.monotonic() - start
    out = r.stdout + r.stderr
    reported = re.search(r"in ([\d.]+) seconds \(([\d.]+) kbit/s\)", out)
    status = "ok" if r.returncode == 0 else "FAILED"
    detail = f"{reported.group(1)}s {reported.group(2)}kbit/s" if reported else "-"
    print(f"{status}  wall {elapsed:.1f}s  esptool {detail}")
    if r.returncode:
        print(out[-1500:])
    return label, status, elapsed, detail


def main():
    port = bridge_port()
    chip, _, _ = detect_chip(port)
    fw = firmware()
    print(f"port {port}   chip {chip}   image {fw.name}")
    print("this erases the whole flash, filesystem included")
    input("enter to start, ctrl+c to abort ")

    runs = [
        ("erase-flash", ["erase-flash"], 2000000),
        ("write compressed 2M", ["write-flash", "0", str(fw)], 2000000),
        ("write uncompressed 2M", ["write-flash", "--no-compress", "0", str(fw)], 2000000),
        ("write compressed 921600", ["write-flash", "0", str(fw)], 921600),
        ("write compressed 460800", ["write-flash", "0", str(fw)], 460800),
    ]

    rows = [measure(port, chip, *run) for run in runs]

    lines = [f"port {port}   chip {chip}   image {fw.name}", ""]
    lines += [f"{label:26} {status:7} wall {elapsed:6.1f}s   {detail}" for label, status, elapsed, detail in rows]
    text = "\n".join(lines)
    RESULTS.write_text(text + "\n")
    print("\n" + text)
    print(f"\nwritten to {RESULTS}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except SystemExit as e:
        if e.code not in (0, None):
            print(f"\n{e.code}")
    except Exception:
        import traceback

        traceback.print_exc()
    input("\npress enter to close ")

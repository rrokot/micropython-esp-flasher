"""Unpack a release archive and check that the packaged program runs.

Checks the license files, runs the program with --version and --help and, for Windows packages
on Windows, checks the embedded version resource and icon. Without an argument it checks the
single archive in dist/. Uses only the standard library.
"""

import argparse
import os
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

NAME = "micropython-esp-flasher"
ROOT = Path(__file__).resolve().parent.parent


def find_archive() -> Path:
    dist = ROOT / "dist"
    archives = sorted(dist.glob("*.zip")) + sorted(dist.glob("*.tar.gz"))
    if len(archives) != 1:
        sys.exit(f"Expected one package archive in {dist}, found {len(archives)}.")
    return archives[0]


def unpack(archive: Path, destination: Path) -> None:
    if archive.name.endswith(".zip"):
        with zipfile.ZipFile(archive) as source:
            source.extractall(destination)
    else:
        with tarfile.open(archive) as source:
            # The data filter keeps permissions and refuses unsafe paths on Python 3.12 and later.
            if hasattr(tarfile, "data_filter"):
                source.extractall(destination, filter="data")
            else:
                source.extractall(destination)


def product_name(path: Path) -> str | None:
    import ctypes
    from ctypes import wintypes

    version = ctypes.WinDLL("version")
    version.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, wintypes.LPDWORD]
    version.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    version.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID]
    version.GetFileVersionInfoW.restype = wintypes.BOOL
    version.VerQueryValueW.argtypes = [
        wintypes.LPCVOID,
        wintypes.LPCWSTR,
        ctypes.POINTER(wintypes.LPVOID),
        ctypes.POINTER(wintypes.UINT),
    ]
    version.VerQueryValueW.restype = wintypes.BOOL

    size = version.GetFileVersionInfoSizeW(str(path), None)
    if not size:
        return None
    data = ctypes.create_string_buffer(size)
    if not version.GetFileVersionInfoW(str(path), 0, size, data):
        return None
    value = wintypes.LPVOID()
    length = wintypes.UINT()
    if not version.VerQueryValueW(data, "\\VarFileInfo\\Translation", ctypes.byref(value), ctypes.byref(length)):
        return None
    if length.value < 4:
        return None
    language, codepage = ctypes.cast(value, ctypes.POINTER(ctypes.c_ushort * 2)).contents
    key = f"\\StringFileInfo\\{language:04x}{codepage:04x}\\ProductName"
    if not version.VerQueryValueW(data, key, ctypes.byref(value), ctypes.byref(length)):
        return None
    return ctypes.wstring_at(value.value, length.value).rstrip("\0")


def icon_count(path: Path) -> int:
    import ctypes
    from ctypes import wintypes

    shell = ctypes.WinDLL("shell32")
    shell.ExtractIconExW.argtypes = [wintypes.LPCWSTR, ctypes.c_int, wintypes.LPVOID, wintypes.LPVOID, wintypes.UINT]
    shell.ExtractIconExW.restype = wintypes.UINT
    # Index -1 with no output arrays returns the number of icons in the file.
    return shell.ExtractIconExW(str(path), -1, None, None, 0)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("archive", nargs="?", type=Path, help="archive to check (default: the one in dist/)")
    args = parser.parse_args()
    archive = args.archive or find_archive()
    windows = archive.name.endswith(".zip")

    with tempfile.TemporaryDirectory(prefix=f"{NAME}-package-test-") as temporary:
        unpack(archive, Path(temporary))
        package = Path(temporary, NAME)
        for name in ("LICENSE", "THIRD-PARTY-LICENSES.html"):
            if not (package / name).is_file():
                sys.exit(f"Missing package file: {name}")
        executable = package / (f"{NAME}.exe" if windows else NAME)
        for option in ("--version", "--help"):
            subprocess.run([str(executable), option], check=True)
        if windows and os.name == "nt":
            if product_name(executable) != NAME:
                sys.exit("Missing Windows version resource.")
            if icon_count(executable) < 1:
                sys.exit("Missing embedded Windows icon.")
    print(f"{archive.name}: package is complete")


if __name__ == "__main__":
    main()

"""Portable Windows toolchain for local development; nothing is installed on the system.

  py scripts/toolchain.py install   download Rust, the MSVC libraries and LLVM into one folder
  py scripts/toolchain.py remove    delete that folder

Then build and test natively with the same target as CI:

  D:\\micropython-esp-flasher-toolchain\\cargo.cmd test
  D:\\micropython-esp-flasher-toolchain\\cargo.cmd run -- plan

Rust follows the stable channel like CI. The MSVC CRT and Windows SDK come from Microsoft through
xwin, which requires accepting the Microsoft license. LLVM provides clang-cl for C dependencies,
lld-link for linking and llvm-rc for the icon. Build output goes to the toolchain folder, not C:.
Requires Python 3.14 or later for .tar.zst archives.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

DEFAULT_DIR = Path(r"D:\micropython-esp-flasher-toolchain")
XWIN_VERSION = "0.10.0"
LLVM_VERSION = "23.1.3"
RUSTUP_INIT = "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
XWIN = (
    f"https://github.com/Jake-Shadle/xwin/releases/download/{XWIN_VERSION}/"
    f"xwin-{XWIN_VERSION}-x86_64-pc-windows-msvc.tar.gz"
)
LLVM = (
    f"https://github.com/llvm/llvm-project/releases/download/llvmorg-{LLVM_VERSION}/"
    f"clang+llvm-{LLVM_VERSION}-x86_64-pc-windows-msvc.tar.zst"
)
# clang and lld pick their mode from the executable name, so copies are saved under the MSVC-style names.
LLVM_TOOLS = {
    "clang-cl.exe": "clang-cl.exe",
    "clang.exe": "clang-cl.exe",
    "lld-link.exe": "lld-link.exe",
    "lld.exe": "lld-link.exe",
    "llvm-lib.exe": "llvm-lib.exe",
    "llvm-rc.exe": "llvm-rc.exe",
}
TARGET = "x86_64-pc-windows-msvc"


def download(url: str, path: Path) -> None:
    print(f"Downloading {url}")
    with urllib.request.urlopen(url) as response, path.open("wb") as file:
        shutil.copyfileobj(response, file, 1024 * 1024)


def install_rust(root: Path, downloads: Path) -> None:
    init = downloads / "rustup-init.exe"
    download(RUSTUP_INIT, init)
    env = dict(os.environ, RUSTUP_HOME=str(root / "rustup"), CARGO_HOME=str(root / "cargo"))
    subprocess.run(
        [str(init), "-y", "--no-modify-path", "--profile", "minimal", "--default-toolchain", "stable",
         "--component", "clippy", "--component", "rustfmt"],
        env=env,
        check=True,
    )


def install_msvc(root: Path, downloads: Path) -> None:
    archive = downloads / "xwin.tar.gz"
    download(XWIN, archive)
    with tarfile.open(archive) as source:
        member = next(m for m in source.getmembers() if m.name.endswith("/xwin.exe"))
        member.name = "xwin.exe"
        source.extract(member, downloads, filter="data")
    print("Downloading the MSVC CRT and Windows SDK through xwin")
    subprocess.run(
        [str(downloads / "xwin.exe"), "--accept-license", "--cache-dir", str(downloads / "xwin-cache"),
         "splat", "--use-winsysroot-style", "--preserve-ms-arch-notation", "--output", str(root / "msvc")],
        check=True,
    )


def install_llvm(root: Path, downloads: Path) -> None:
    archive = downloads / "llvm.tar.zst"
    download(LLVM, archive)
    print("Unpacking LLVM tools")
    llvm = root / "llvm"
    from compression.zstd import DecompressionParameter

    # The LLVM archive is compressed with a long window, which needs a larger decoder limit.
    options = {DecompressionParameter.window_log_max: 31}
    with tarfile.open(archive, "r:zst", options=options) as source:
        for member in source:
            parts = member.name.split("/", 1)
            if len(parts) < 2 or not (member.isfile() or member.islnk()):
                continue
            relative = parts[1]
            name = Path(relative).name
            if relative.startswith("bin/") and name in LLVM_TOOLS:
                destination = llvm / "bin" / LLVM_TOOLS[name]
            elif relative.startswith("lib/clang/") and "/include/" in relative:
                destination = llvm / relative
            else:
                continue
            if destination.exists():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as data, destination.open("wb") as file:
                shutil.copyfileobj(data, file)


def configure(root: Path) -> None:
    msvc = root / "msvc"
    vc = max((msvc / "VC" / "Tools" / "MSVC").iterdir())
    sdk_lib = max((msvc / "Windows Kits" / "10" / "Lib").iterdir())
    sdk_include = msvc / "Windows Kits" / "10" / "Include" / sdk_lib.name
    libraries = [vc / "lib" / "x64", sdk_lib / "um" / "x64", sdk_lib / "ucrt" / "x64"]
    includes = [vc / "include", *(sdk_include / name for name in ("ucrt", "um", "shared", "winrt"))]
    bin_dir = root / "llvm" / "bin"
    # Plain rustc calls, such as the self-update test fixture, look for link.exe on PATH.
    link = bin_dir / "link.exe"
    if not link.exists():
        os.link(bin_dir / "lld-link.exe", link)

    target = TARGET.replace("-", "_")
    tools = bin_dir.as_posix()
    (root / "cargo" / "config.toml").write_text(
        f"""[target.{TARGET}]
linker = "{tools}/lld-link.exe"
# Match CI.
rustflags = ["-Ctarget-feature=+crt-static"]

[env]
CC_{target} = "{tools}/clang-cl.exe"
AR_{target} = "{tools}/llvm-lib.exe"
RC_PATH = "{tools}/llvm-rc.exe"
""",
        encoding="utf-8",
    )
    lines = [
        "@echo off",
        'set "RUSTUP_HOME=%~dp0rustup"',
        'set "CARGO_HOME=%~dp0cargo"',
        'set "CARGO_TARGET_DIR=%~dp0target"',
        r'set "PATH=%~dp0llvm\bin;%~dp0cargo\bin;%PATH%"',
        f'set "LIB={";".join(map(str, libraries))}"',
        f'set "INCLUDE={";".join(map(str, includes))}"',
        # The Microsoft libraries reference debug files that are not downloaded.
        'set "LINK=/ignore:4099"',
        r'"%~dp0cargo\bin\cargo.exe" %*',
    ]
    (root / "cargo.cmd").write_text("\r\n".join(lines) + "\r\n", encoding="ascii", newline="")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["install", "remove"])
    parser.add_argument("--dir", type=Path, default=DEFAULT_DIR, help=f"toolchain folder (default: {DEFAULT_DIR})")
    args = parser.parse_args()
    root = args.dir.resolve()

    if args.command == "remove":
        shutil.rmtree(root, ignore_errors=True)
        print(f"Removed {root}")
        return
    if sys.version_info < (3, 14):
        sys.exit("Python 3.14 or later is required to unpack .tar.zst archives.")
    if root.exists():
        sys.exit(f"{root} already exists; remove it first.")
    root.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="micropython-esp-flasher-toolchain-", dir=root.parent) as temporary:
        downloads = Path(temporary)
        install_rust(root, downloads)
        install_msvc(root, downloads)
        install_llvm(root, downloads)
    configure(root)
    print(f"Toolchain ready. Use {root / 'cargo.cmd'}")


if __name__ == "__main__":
    main()

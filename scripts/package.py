"""Package a release executable with its licenses as dist/micropython-esp-flasher-<platform>-<arch>.

Windows packages are .zip archives, Linux and macOS packages are .tar.gz archives with an
executable program. Every archive gets a .sha256 file next to it. Uses only the standard library.
"""

import argparse
import hashlib
import io
import sys
import tarfile
import time
import zipfile
from pathlib import Path

NAME = "micropython-esp-flasher"
ROOT = Path(__file__).resolve().parent.parent


def files(executable: Path, notices: Path, platform: str) -> list[tuple[str, Path, int]]:
    program = f"{NAME}.exe" if platform == "windows" else NAME
    return [
        (program, executable, 0o755),
        ("THIRD-PARTY-LICENSES.html", notices, 0o644),
        ("LICENSE", ROOT / "LICENSE", 0o644),
    ]


def write_zip(archive: Path, entries: list[tuple[str, Path, int]]) -> None:
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
        for name, source, _ in entries:
            output.write(source, f"{NAME}/{name}")


def write_tar(archive: Path, entries: list[tuple[str, Path, int]]) -> None:
    def info(name: str, mode: int, mtime: float, size: int = 0, directory: bool = False) -> tarfile.TarInfo:
        item = tarfile.TarInfo(name)
        item.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
        item.mode = mode
        item.mtime = int(mtime)
        item.size = size
        return item

    with tarfile.open(archive, "w:gz") as output:
        output.addfile(info(NAME, 0o755, time.time(), directory=True))
        for name, source, mode in entries:
            data = source.read_bytes()
            # Set modes explicitly so the program stays executable when packaged on Windows.
            output.addfile(info(f"{NAME}/{name}", mode, source.stat().st_mtime, len(data)), io.BytesIO(data))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--executable", type=Path, default=Path(f"target/release/{NAME}.exe"))
    parser.add_argument("--notices", type=Path, default=Path("target/THIRD-PARTY-LICENSES.html"))
    parser.add_argument("--platform", choices=["windows", "linux", "macos"], default="windows")
    parser.add_argument("--arch", choices=["x64", "arm64"], default="x64")
    args = parser.parse_args()

    executable = ROOT / args.executable
    notices = ROOT / args.notices
    if not executable.is_file():
        sys.exit("Build the release executable first.")
    if not notices.is_file():
        sys.exit("Generate the dependency license notices first.")

    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    entries = files(executable, notices, args.platform)
    if args.platform == "windows":
        archive = dist / f"{NAME}-{args.platform}-{args.arch}.zip"
        write_zip(archive, entries)
    else:
        archive = dist / f"{NAME}-{args.platform}-{args.arch}.tar.gz"
        write_tar(archive, entries)

    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    Path(f"{archive}.sha256").write_text(f"{digest}  {archive.name}\n", encoding="ascii", newline="\n")
    print(f"{archive}\nSHA-256: {digest}")


if __name__ == "__main__":
    main()

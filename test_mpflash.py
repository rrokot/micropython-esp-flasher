import io
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch

import mpflash


class FirmwareTests(unittest.TestCase):
    board = "ESP32_GENERIC_S3"
    base = "ESP32_GENERIC_S3-20250911-v1.26.1.bin"
    octal = "ESP32_GENERIC_S3-SPIRAM_OCT-20250911-v1.26.1.bin"

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.cache = Path(directory.name)
        cache_patch = patch.object(mpflash, "CACHE", self.cache)
        cache_patch.start()
        self.addCleanup(cache_patch.stop)

    def store(self, name, data=b"firmware"):
        path = self.cache / name
        path.write_bytes(data)
        return path

    def test_cache_selects_latest_stable_per_variant(self):
        newer = "ESP32_GENERIC_S3-20260101-v1.27.0.bin"
        for name in (self.base, self.octal, newer,
                     "ESP32_GENERIC_S3-20260102-v1.28.0-preview.bin",
                     "ESP32_GENERIC_S3-20260103-v1.28.0.bin.part",
                     "ESP32_GENERIC-20260101-v1.27.0.bin"):
            self.store(name)
        self.store("ESP32_GENERIC_S3-20260104-v1.29.0.bin", b"")
        builds = mpflash.cached_builds(self.board)
        self.assertEqual(set(builds), {None, "SPIRAM_OCT"})
        self.assertEqual(builds[None][2:], (newer, "1.27.0"))
        self.assertEqual(builds["SPIRAM_OCT"][2], self.octal)

    def test_offline_uses_existing_cache_without_downloading(self):
        path = self.store(self.base)
        with patch.object(mpflash.urllib.request, "urlopen", side_effect=urllib.error.URLError("offline")) as request:
            with redirect_stdout(io.StringIO()) as output:
                builds = mpflash.fetch_builds(self.board, check_online=True)
                result = mpflash.download(builds[None][1], builds[None][2])
        self.assertEqual(result, path)
        self.assertEqual(request.call_count, 1)
        self.assertIn("offline: using cached firmware", output.getvalue())

    def test_offline_without_matching_cache_explains_preparation(self):
        self.store("ESP32_GENERIC-20260101-v1.27.0.bin")
        with patch.object(mpflash.urllib.request, "urlopen", side_effect=TimeoutError):
            with self.assertRaisesRegex(SystemExit, "no cached firmware.*ESP32_GENERIC_S3"):
                mpflash.fetch_builds(self.board)

    def test_online_uses_catalog_even_with_older_cached_firmware(self):
        self.store(self.base)
        newer = "ESP32_GENERIC_S3-20260101-v1.27.0.bin"
        response = MagicMock()
        response.read.return_value = f'<a href="/resources/firmware/{newer}">download</a>'.encode()
        with patch.object(mpflash.urllib.request, "urlopen") as request:
            request.return_value.__enter__.return_value = response
            builds = mpflash.fetch_builds(self.board, check_online=True)
        self.assertEqual(builds[None][2], newer)

    def test_local_firmware_does_not_attempt_any_network_request(self):
        self.store(self.base)
        with patch.object(mpflash.urllib.request, "urlopen", side_effect=AssertionError("network request")) as request:
            with redirect_stdout(io.StringIO()):
                builds = mpflash.fetch_builds(self.board)
                path = mpflash.download(builds[None][1], builds[None][2])
        request.assert_not_called()
        self.assertEqual(path, self.cache / self.base)

    def test_download_publishes_only_complete_firmware(self):
        response = MagicMock()
        response.headers = {"Content-Length": "8"}
        response.read.side_effect = [b"firmware", b""]
        with patch.object(mpflash.urllib.request, "urlopen") as request, redirect_stdout(io.StringIO()):
            request.return_value.__enter__.return_value = response
            path = mpflash.download("https://example.invalid/firmware", self.base)
        self.assertEqual(path.read_bytes(), b"firmware")
        self.assertFalse(path.with_suffix(".bin.part").exists())

    def test_failed_and_truncated_downloads_leave_no_firmware(self):
        for chunks in ([b"part", urllib.error.URLError("disconnected")], [b"part", b""], [b""]):
            with self.subTest(chunks=chunks):
                response = MagicMock()
                response.headers = {"Content-Length": "8"}
                response.read.side_effect = chunks
                with patch.object(mpflash.urllib.request, "urlopen") as request, redirect_stdout(io.StringIO()):
                    request.return_value.__enter__.return_value = response
                    with self.assertRaises(OSError):
                        mpflash.download("https://example.invalid/firmware", self.base)
                self.assertEqual(list(self.cache.iterdir()), [])

    def test_offline_main_can_flash_when_only_octal_variant_is_cached(self):
        path = self.store(self.octal)
        with patch.object(mpflash.sys.stdin, "isatty", return_value=True), \
                patch.object(mpflash, "choose_port", return_value="COM5"), \
                patch.object(mpflash, "port_info", return_value="test adapter"), \
                patch.object(mpflash, "probe_repl", return_value=""), \
                patch.object(mpflash, "detect_chip", return_value=("ESP32-S3", 0, "8MB")), \
                patch.object(mpflash, "bootloader_offset", return_value=0), \
                patch.object(mpflash, "ask", return_value=""), \
                patch.object(mpflash, "port_snapshot", return_value={"COM5"}), \
                patch.object(mpflash, "wait_for_board", return_value="COM5"), \
                patch.object(mpflash.time, "sleep"), \
                patch.object(mpflash.urllib.request, "urlopen", side_effect=urllib.error.URLError("offline")), \
                patch.object(mpflash, "flash", return_value=115200) as flash, \
                redirect_stdout(io.StringIO()):
            mpflash.main()
        flash.assert_called_once_with("COM5", "ESP32-S3", path, False)


if __name__ == "__main__":
    unittest.main()

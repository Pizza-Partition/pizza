import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("windows_cache", Path(__file__).with_name("windows-cache.py"))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class BaselineCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / "base"
        self.base.mkdir()
        self.inputs = {"schema": 1, "image": {"sha256": "iso-sha"}, "guest_sha256": "guest-sha"}
        self.raw = b"\0" * (1024 * 1024) + b"preserved Windows disk contents" + b"\0" * 1024
        self.raw += b"\0" * (-len(self.raw) % 512)
        (self.base / "windows.raw").write_bytes(self.raw)
        for name in ("OVMF_CODE.fd", "OVMF_VARS.fd"):
            (self.base / name).write_bytes(name.encode())
        for name in ("windows.raw", "OVMF_CODE.fd", "OVMF_VARS.fd"):
            (self.base / name).chmod(0o444)
        (self.base / "baseline.json").write_text(json.dumps({
            "status": "ready", "transport": "agent", "updates_disabled": True,
            "guest_sha256": "guest-sha", "image": {"sha256": "iso-sha"},
        }))
        self.saved = self.root / "cache"

    def test_round_trip_preserves_disk_firmware_and_read_only_permissions(self):
        cache.pack(self.base, self.saved, self.inputs)
        restored = self.root / "restored"
        cache.restore(self.saved, restored, self.inputs)
        self.assertEqual((restored / "windows.raw").read_bytes(), self.raw)
        for name in ("windows.raw", "OVMF_CODE.fd", "OVMF_VARS.fd"):
            self.assertFalse((restored / name).stat().st_mode & 0o222)
        self.assertEqual((restored / "OVMF_VARS.fd").read_bytes(), b"OVMF_VARS.fd")

    def test_input_change_rejects_cache_before_creating_baseline(self):
        cache.pack(self.base, self.saved, self.inputs)
        restored = self.root / "restored"
        with self.assertRaisesRegex(ValueError, "inputs"):
            cache.restore(self.saved, restored, {**self.inputs, "guest_sha256": "new-guest"})
        self.assertFalse(restored.exists())

    def test_corrupted_disk_or_firmware_is_not_restored(self):
        cache.pack(self.base, self.saved, self.inputs)
        (self.saved / "OVMF_VARS.fd").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "checksum"):
            cache.restore(self.saved, self.root / "restored", self.inputs)

    def test_unfrozen_and_writable_baselines_cannot_be_cached(self):
        (self.base / "windows.raw").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "immutable"):
            cache.pack(self.base, self.saved, self.inputs)
        (self.base / "windows.raw").chmod(0o444)
        record = json.loads((self.base / "baseline.json").read_text())
        record["updates_disabled"] = False
        (self.base / "baseline.json").write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "frozen"):
            cache.pack(self.base, self.saved, self.inputs)

    def test_same_inputs_have_same_key_regardless_of_json_field_order(self):
        self.assertEqual(cache.key(self.inputs), cache.key(dict(reversed(list(self.inputs.items())))))


if __name__ == "__main__":
    unittest.main()

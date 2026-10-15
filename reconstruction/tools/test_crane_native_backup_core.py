"""G-11 Native N0: synthetic ZIP64 Info test vectors and source safety.

These Python tests run on Windows/macOS. The Objective-C Foundation smoke
is additionally compiled on macOS CI and linked into CranePrefs on Theos.
"""
from __future__ import annotations

import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile
import zlib

import native_backup_reader_fixture as gen
from test_crane_original_archive_audit import ORIGINAL_FIXTURE

ROOT = Path(__file__).resolve().parents[2]


class NativeCoreFixtureTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="crane-native-core-")
        self.addCleanup(folder.cleanup)
        self.paths = gen.create(Path(folder.name))

    def test_zip64_local_first_info_binary_plist(self):
        archive = self.paths[0]
        with archive.open("rb") as src:
            header = src.read(30)
        self.assertEqual(header[:4], b"PK\x03\x04")
        self.assertEqual(struct.unpack_from("<I", header, 18)[0], 0xFFFFFFFF)
        self.assertEqual(struct.unpack_from("<I", header, 22)[0], 0xFFFFFFFF)
        self.assertEqual(struct.unpack_from("<H", header, 28)[0], 20)
        with zipfile.ZipFile(archive) as zf:
            info = zf.infolist()[0]
            self.assertEqual(info.filename, "Info.plist")
            self.assertTrue(info.flag_bits & 8)
            self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)
            decoded = plistlib.loads(zf.read("Info.plist"))
            self.assertEqual(decoded["originalPaths"],
                             gen.INFO["originalPaths"])
            self.assertEqual(decoded["deviceIdentifierForVendor"],
                             gen.INFO["deviceIdentifierForVendor"])

    def test_valid_zip64_descriptor_and_raw_deflate_stream_complete(self):
        archive = self.paths[0]
        raw = archive.read_bytes()
        with zipfile.ZipFile(archive, "r") as zf:
            member = zf.infolist()[0]
            self.assertEqual(member.filename, "Info.plist")
            name_len, extra_len = struct.unpack_from("<HH", raw, 26)
            offset = 30 + name_len + extra_len
            compressed = raw[offset:offset + member.compress_size]
            stream = zlib.decompressobj(-zlib.MAX_WBITS)
            payload = stream.decompress(compressed) + stream.flush()
            self.assertTrue(stream.eof)
            self.assertEqual(stream.unused_data, b"")
            self.assertEqual(len(payload), member.file_size)
            self.assertEqual(zlib.crc32(payload), member.CRC)
            descriptor_offset = offset + member.compress_size
            descriptor = raw[descriptor_offset:descriptor_offset + 24]
            self.assertEqual(descriptor[:4], b"PK\x07\x08")
            self.assertEqual(
                struct.unpack_from("<IQQ", descriptor, 4),
                (member.CRC, member.compress_size, member.file_size))
            self.assertEqual(raw[descriptor_offset + 24:
                                 descriptor_offset + 28], b"PK\x03\x04")

    def test_bad_crc_descriptor_rejected_by_native_test_vector(self):
        good, bad = self.paths[:2]
        self.assertEqual(good.stat().st_size, bad.stat().st_size)
        with zipfile.ZipFile(bad) as zf:
            # The ZIP central directory remains valid, but the local
            # descriptor CRC differs: native FIRST-ENTRY parser must refuse.
            first = zf.infolist()[0]
            raw = bad.read_bytes()
            local_end = 30 + len(first.filename) + 20 + first.compress_size
            self.assertEqual(raw[local_end:local_end + 4], b"PK\x07\x08")
            self.assertNotEqual(
                struct.unpack_from("<I", raw, local_end + 4)[0],
                first.CRC)

    def test_local_zip64_zero_sizes_resolve_to_central_actual_sizes(self):
        raw = self.paths[0].read_bytes()
        with zipfile.ZipFile(self.paths[0]) as zf:
            member = zf.infolist()[0]
            self.assertNotEqual(member.compress_size, 0)
            self.assertNotEqual(member.file_size, 0)
        name_size, extra_size = struct.unpack_from("<HH", raw, 26)
        extra = raw[30 + name_size:30 + name_size + extra_size]
        self.assertEqual(extra[:4], b"\x01\x00\x10\x00")
        self.assertEqual(struct.unpack_from("<QQ", extra, 4), (0, 0))
        eocd = raw.rfind(b"PK\x05\x06")
        self.assertGreater(eocd, 0)
        central_offset = struct.unpack_from("<I", raw, eocd + 16)[0]
        self.assertEqual(raw[central_offset:central_offset + 4],
                         b"PK\x01\x02")
        central_compressed, central_uncompressed = struct.unpack_from(
            "<II", raw, central_offset + 20)
        self.assertEqual((central_compressed, central_uncompressed),
                         (member.compress_size, member.file_size))

    def test_tampered_central_size_and_crc_are_distinct_invalid_vectors(self):
        good, _, _, altered_size, altered_crc = self.paths
        baseline = good.read_bytes()
        size_raw, crc_raw = altered_size.read_bytes(), altered_crc.read_bytes()
        eocd = baseline.rfind(b"PK\x05\x06")
        offset = struct.unpack_from("<I", baseline, eocd + 16)[0]
        self.assertEqual(size_raw[offset + 20] ^ baseline[offset + 20], 1)
        self.assertEqual(crc_raw[offset + 16] ^ baseline[offset + 16], 1)
        self.assertEqual(len(baseline), len(size_raw))
        self.assertEqual(len(baseline), len(crc_raw))

    def test_nonbinary_plist_is_readable_zip_but_invalid_info(self):
        with zipfile.ZipFile(self.paths[2]) as zf:
            self.assertEqual(zf.read("Info.plist"), b"not-a-binary-property-list")

    @unittest.skipUnless(ORIGINAL_FIXTURE.is_file(),
                         "real Chrome original remains local and ignored by Git")
    def test_original_single_local_zip64_descriptor_matches_native_contract(self):
        # Header-only: no Chrome contents, identifiers or paths disclosed.
        with zipfile.ZipFile(ORIGINAL_FIXTURE) as zf:
            first = zf.infolist()[0]
            self.assertEqual(first.filename, "Info.plist")
            self.assertEqual(first.compress_type, zipfile.ZIP_DEFLATED)
            self.assertEqual(first.flag_bits, 0x0808)
            with ORIGINAL_FIXTURE.open("rb") as reader:
                local = reader.read(30)
                self.assertEqual(local[:4], b"PK\x03\x04")
                name_len = struct.unpack_from("<H", local, 26)[0]
                extra_len = struct.unpack_from("<H", local, 28)[0]
                self.assertEqual(extra_len, 20)
                self.assertEqual(struct.unpack_from("<I", local, 18)[0],
                                 0xFFFFFFFF)
                self.assertEqual(struct.unpack_from("<I", local, 22)[0],
                                 0xFFFFFFFF)
                reader.seek(30 + name_len + extra_len + first.compress_size)
                descriptor = reader.read(24)
                self.assertEqual(descriptor[:4], b"PK\x07\x08")
                self.assertEqual(struct.unpack_from("<I", descriptor, 4)[0],
                                 first.CRC)
                self.assertEqual(struct.unpack_from("<Q", descriptor, 8)[0],
                                 first.compress_size)
                self.assertEqual(struct.unpack_from("<Q", descriptor, 16)[0],
                                 first.file_size)

    def test_five_disposable_vectors_only(self):
        self.assertEqual({p.name for p in self.paths}, {
            "crane-native-valid.cranect", "crane-native-bad-crc.cranect",
            "crane-native-invalid-info.cranect",
            "crane-native-bad-central-size.cranect",
            "crane-native-bad-central-crc.cranect",
        })
        for path in self.paths:
            self.assertLess(path.stat().st_size, 1024 * 1024)

    def test_native_header_declares_only_nonmutating_apis(self):
        source = (ROOT / "reconstruction/sources/prefs/"
                  "CRBackupNativeCore.h").read_text(encoding="utf-8")
        self.assertIn("readSingleBackupInfoAtPath:", source)
        self.assertIn("binarySingleInfoForApplicationIdentifier:", source)
        self.assertIn("writableMetadataAttributes:", source)
        for dangerous in ("restoreContainer", "wipeContainer",
                          "removeItemAtPath:", "createBackupAtPath:"):
            self.assertNotIn(dangerous, source)


if __name__ == "__main__":
    unittest.main()

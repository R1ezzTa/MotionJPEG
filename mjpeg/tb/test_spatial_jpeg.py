import io
import struct
import sys
import unittest
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_jpeg import SpatialEncoder, SpatialDecoder, split_jpeg
from spatial_reference import encode_restart
from jpeg_model import encode, tables
from block_records import BlockRecords


def fixture(change=False, quality=85, gray=False):
    row, col = np.indices((16, 128))
    y = ((row * 2 + col * 3) & 255).astype(np.uint8)
    if change:
        y[:8, :64] = (y[:8, :64].astype(np.uint16) + 17).astype(np.uint8)
    cb = np.full((16, 64), 96, np.uint8)
    cr = np.full((16, 64), 160, np.uint8)
    return encode_restart(y, cb, cr, gray, tables(quality)), encode(y, cb, cr, gray, tables(quality))


class SpatialTests(unittest.TestCase):
    def test_adaptive_flag_requires_refresh_and_preserves_decoder_reference_on_error(self):
        encoder, decoder = SpatialEncoder(), SpatialDecoder()
        jpeg, _ = fixture()
        def packet(mode, frame, refresh=False):
            p = encoder.encode(jpeg, frame, force_refresh=refresh)
            return b'SPJ2' + bytes([p[4] | (2 if mode else 0)]) + p[5:9] + b'\x3c' + p[9:]
        decoder.decode(packet(True, 0), 0)
        self.assertTrue(decoder.last_stats['adaptive'])
        invalid = packet(False, 1)
        with self.assertRaisesRegex(ValueError, 'adaptive mode changed'):
            decoder.decode(invalid, 1)
        self.assertEqual(decoder.frame_id, 0)
        self.assertTrue(decoder.adaptive)
        decoder.decode(packet(False, 2, True), 2)
        self.assertFalse(decoder.last_stats['adaptive'])

    def test_spj2_threshold_change_requires_refresh_and_is_atomic(self):
        encoder, decoder = SpatialEncoder(), SpatialDecoder()
        jpeg, _ = fixture()
        def spj2(packet, threshold):
            return b'SPJ2' + packet[4:9] + bytes([threshold]) + packet[9:]
        self.assertEqual(decoder.decode(spj2(encoder.encode(jpeg, 0), 16), 0), jpeg)
        packet = encoder.encode(jpeg, 1)
        with self.assertRaisesRegex(ValueError, 'threshold changed'):
            decoder.decode(spj2(packet, 32), 1)
        self.assertEqual(decoder.frame_id, 0)
        self.assertEqual(decoder.threshold, 16)
        self.assertEqual(decoder.decode(spj2(packet, 16), 1), jpeg)
        self.assertEqual(decoder.last_stats['threshold'], 16)
        self.assertEqual(decoder.decode(spj2(encoder.encode(jpeg, 2, force_refresh=True), 32), 2), jpeg)
        self.assertEqual(decoder.last_stats['threshold'], 32)

    def test_spj2_can_retain_reference_different_from_current_input(self):
        encoder, decoder = SpatialEncoder(), SpatialDecoder()
        original, _ = fixture(); changed, _ = fixture(True)
        def spj2(packet): return b'SPJ2' + packet[4:9] + b'\x20' + packet[9:]
        decoder.decode(spj2(encoder.encode(original, 0)), 0)
        # COPY means reuse the already displayed reference, not this new input.
        retained = decoder.decode(spj2(encoder.encode(original, 1)), 1)
        self.assertEqual(retained, original)
        self.assertNotEqual(retained, changed)
        self.assertEqual(decoder.reference.groups, split_jpeg(original).groups)

    def test_exact_spatial_reconstruction_and_no_added_pixel_error(self):
        encoder, decoder = SpatialEncoder(), SpatialDecoder()
        for i in range(3):
            jpeg, plain = fixture(change=i == 2)
            reconstructed = decoder.decode(encoder.encode(jpeg, i), i)
            self.assertEqual(reconstructed, jpeg)
            with Image.open(io.BytesIO(jpeg)) as a, Image.open(io.BytesIO(plain)) as b:
                self.assertEqual(a.convert('RGB').tobytes(), b.convert('RGB').tobytes())
            if i == 1:
                self.assertEqual(decoder.last_stats['reused'], 4)
            if i == 2:
                self.assertEqual(decoder.last_stats['reused'], 3)

    def test_reference_updates_after_change_not_just_first_frame(self):
        encoder, decoder = SpatialEncoder(), SpatialDecoder()
        for i, changed in enumerate((False, True, True, False)):
            jpeg, _ = fixture(changed)
            self.assertEqual(decoder.decode(encoder.encode(jpeg, i), i), jpeg)
            if i == 2:
                self.assertEqual(decoder.last_stats['reused'], 4)

    def test_quality_and_periodic_refresh(self):
        encoder, decoder = SpatialEncoder(refresh_period=2), SpatialDecoder()
        for i, quality in enumerate((85, 85, 85, 60)):
            jpeg, _ = fixture(quality=quality)
            decoder.decode(encoder.encode(jpeg, i), i)
            self.assertEqual(decoder.last_stats['keyframe'], i in (0, 2, 3))

    def test_failed_packet_does_not_commit_reference(self):
        encoder, decoder = SpatialEncoder(), SpatialDecoder()
        jpeg, _ = fixture()
        decoder.decode(encoder.encode(jpeg, 0), 0)
        packet = encoder.encode(jpeg, 1)
        for bad in (packet[:-1], packet + b'\x7f\x04\x00', packet[:5] + struct.pack('<I', 77) + packet[9:]):
            with self.assertRaises(ValueError):
                decoder.decode(bad, 1)
            self.assertEqual(decoder.frame_id, 0)
        self.assertEqual(decoder.decode(packet, 1), jpeg)

    def test_missing_reference_rejected_and_refresh_recovers(self):
        encoder, decoder = SpatialEncoder(), SpatialDecoder()
        jpeg, _ = fixture()
        encoder.encode(jpeg, 0)
        with self.assertRaisesRegex(ValueError, 'reference'):
            decoder.decode(encoder.encode(jpeg, 1), 1)
        self.assertEqual(decoder.decode(encoder.encode(jpeg, 2, force_refresh=True), 2), jpeg)

    def test_restart_marker_order_and_geometry(self):
        jpeg, _ = fixture()
        with self.assertRaisesRegex(ValueError, 'sequence'):
            split_jpeg(jpeg.replace(b'\xff\xd0', b'\xff\xd4', 1))
        with self.assertRaises(ValueError):
            split_jpeg(jpeg[:-2])
        gray, _ = fixture(gray=True)
        parsed = split_jpeg(gray)
        self.assertEqual(parsed.rectangle(1), (32, 0, 32, 8))

    def test_mblk_descriptor_and_transmitted_length_remain_valid(self):
        encoder = SpatialEncoder()
        wire = bytearray()
        def block(kind, body=b'', flags=0):
            wire.extend(struct.pack('<4sBBH', b'MBLK', kind, flags, len(body)) + body)
        block(6)
        jpeg, _ = fixture()
        for i in range(2):
            packet = encoder.encode(jpeg, i)
            for p in range(0, len(packet), 1024):
                flags = int(p == 0) | (2 if p + 1024 >= len(packet) else 0)
                block(0, struct.pack('<I', i) + packet[p:p + 1024], flags)
            block(1, struct.pack('<7I', 0x4d4a1400, i, i * 3333333, 0,
                                 len(packet), 128 | 16 << 16, 0))
        block(5)
        source = io.BytesIO(wire)
        records = BlockRecords(source.read)
        frames = []
        while True:
            kind, value = records.next()
            if kind == 'frame':
                frames.append(value)
            if kind == 'end':
                break
        self.assertEqual([f.jpeg for f in frames], [jpeg, jpeg])
        self.assertEqual([f.length for f in frames], [len(jpeg), len(jpeg)])
        self.assertEqual(records.spatial_stats['reused'], 4)


if __name__ == '__main__':
    unittest.main()

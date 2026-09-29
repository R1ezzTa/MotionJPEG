"""Validate offline sweep reference updates and same-input comparison."""
import io
import json
from contextlib import redirect_stdout
import tempfile
import unittest
from pathlib import Path

import numpy as np

from analyze_threshold_capture import (ThresholdCacheEncoder, candidate, coefficient_vector,
                                       main, parse_args, parse_header, split_jpeg)
from spatial_jpeg import SpatialDecoder
from spatial_reference import encode_restart
from jpeg_model import encode, tables
from test_camera_receiver import block, frame_blocks


def fixture(level):
    y = np.full((16, 128), level, dtype=np.uint8)
    cb = cr = np.full((16, 64), 128, dtype=np.uint8)
    return encode_restart(y, cb, cr, False, tables(85)), encode(y, cb, cr, False, tables(85))


def prepare(jpeg):
    parsed = split_jpeg(jpeg)
    config = parse_header(parsed.header)
    return parsed, {i: coefficient_vector(group, config) for i, group in enumerate(parsed.groups)}


class ThresholdCaptureAnalysisTests(unittest.TestCase):
    def test_copy_keeps_emitted_reference_until_accumulated_drift_exceeds_deadzone(self):
        frames = [prepare(fixture(level)[0]) for level in (100, 101, 102)]
        threshold = int(np.abs(frames[1][1][0] - frames[0][1][0]).max())
        self.assertGreater(int(np.abs(frames[2][1][0] - frames[0][1][0]).max()), threshold)
        encoder = ThresholdCacheEncoder(threshold)
        decoder = SpatialDecoder()
        decoded = []
        for i, (parsed, vectors) in enumerate(frames):
            decoded.append(decoder.decode(encoder.encode(parsed, vectors, i), i))
            self.assertEqual(decoder.last_stats['reused'], 1 if i == 1 else 0)
        self.assertEqual(split_jpeg(decoded[1]).groups[0], frames[0][0].groups[0])
        self.assertEqual(split_jpeg(decoded[2]).groups[0], frames[2][0].groups[0])

    def test_periodic_refresh_and_exact_zero_baseline(self):
        jpeg, _ = fixture(100)
        parsed, vectors = prepare(jpeg)
        encoder = ThresholdCacheEncoder(0, full_cache=True, refresh_period=2)
        decoder = SpatialDecoder()
        for i in range(4):
            self.assertEqual(decoder.decode(encoder.encode(parsed, vectors, i), i), jpeg)
            self.assertEqual(decoder.last_stats['keyframe'], i % 2 == 0)
            self.assertEqual(decoder.last_stats['reused'], 0 if i % 2 == 0 else len(parsed.groups))

    def test_board_cache_coverage_and_byte_limit(self):
        self.assertTrue(candidate(0, bytes(256)))
        self.assertFalse(candidate(0, bytes(257)))
        self.assertTrue(candidate(191 * 21, bytes(5)))
        self.assertFalse(candidate(192 * 21, bytes(5)))
        self.assertFalse(candidate(1, bytes(5)))
        self.assertTrue(candidate(1, bytes(257), True))

    def test_sweep_records_same_input_rgb_error_and_standard_json(self):
        with tempfile.TemporaryDirectory(prefix='threshold_capture_test_') as temporary:
            directory = Path(temporary)
            capture = directory / 'capture.bin'
            data = block(6)
            for i, level in enumerate((100, 101, 102)):
                _, plain = fixture(level)
                data += frame_blocks(i, 100 + i * 3333333, plain, 128, 16)
            capture.write_bytes(data + block(5))
            with redirect_stdout(io.StringIO()):
                summary = main([str(capture), '--output', str(directory / 'report'), '--skip', '0',
                                '--frames', '3', '--thresholds', '0,16', '--full-cache'])
            saved = json.loads((directory / 'report/summary.json').read_text())
            self.assertEqual(saved['selected_frames'], 3)
            self.assertTrue(summary['modes']['board_cache']['0']['rgb_exact'])
            self.assertIsNone(summary['modes']['board_cache']['0']['rgb_psnr_db'])
            self.assertGreater(summary['modes']['full_cache']['16']['rgb_mae'], 0)
            self.assertGreater(summary['modes']['full_cache']['16']['reused_groups'], 0)
            stats = summary['modes']['board_cache']['16']
            self.assertEqual(stats['cache_region_pixel_fraction'], 0.25)
            self.assertAlmostEqual(stats['cache_region_rgb_mae'], stats['rgb_mae'] * 4)
            self.assertEqual(summary['modes']['full_cache']['16']['cache_region_pixel_fraction'], 1)

    def test_cli_defaults_and_validation(self):
        args = parse_args(['x.bin', '--output', 'out'])
        self.assertEqual((args.frames, args.skip), (12, 100))
        self.assertEqual(args.thresholds, (0, 8, 16, 32, 64, 128, 255))
        for values in ('-1', '256', '1,a'):
            with self.assertRaises(SystemExit):
                parse_args(['x.bin', '--output', 'out', '--thresholds', values])


if __name__ == '__main__':
    unittest.main()

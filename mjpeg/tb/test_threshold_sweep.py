"""Mock USB/controller checks; never opens an FTDI device."""
import argparse
import io
import json
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from block_records import BlockRecords
from spatial_jpeg import SpatialEncoder
from threshold_sweep import ThresholdSweep, parse_thresholds
from test_spatial_coefficients import coefficient_jpeg, values


def block(kind, body=b'', flags=0):
    return struct.pack('<4sBBH', b'MBLK', kind, flags, len(body)) + body


class MockClock:
    def __init__(self):
        self.value = 0

    def __call__(self):
        return self.value


class MockUSB:
    def __init__(self, clock, capable=True, wrong_threshold=False, gap=False, overflow=False, bad_jpeg=False):
        self.clock = clock
        self.capable = capable
        self.wrong_threshold = wrong_threshold
        self.gap = gap
        self.overflow = overflow
        self.bad_jpeg = bad_jpeg
        self.writes = []
        self.queue = [self.camera()]
        self.threshold = 0
        self.running = False
        self.closed = False
        self.frame_id = 0

    def camera(self):
        flags = 1 | 1 << 14 | 1 << 15 | 1 << 16 | 2 << 18 | 2 << 20
        if self.capable:
            flags |= 1 << 31
        return block(7, struct.pack('<8I', flags, 0x5640, 0, 0, 0, 0, int(self.overflow), 0))

    def write(self, command):
        self.writes.append(command)
        if command.startswith(b'T'):
            self.threshold = int(command[1:3], 16)
        if command == b'C':
            self.running = True
            self.queue.append(block(6))
            encoder = SpatialEncoder()
            jpeg = coefficient_jpeg([values(dc=3)])
            if self.bad_jpeg:
                # Preserve structural restart markers so only independent JPEG
                # decode, not the MBLK or spatial parser, detects bad entropy.
                at = jpeg.rfind(b'\xff\xda')
                start = at + 2 + int.from_bytes(jpeg[at + 2:at + 4], 'big')
                jpeg = jpeg[:start] + b'\xff\x00' * 30 + b'\xff\xd9'
            for index in range(3):
                frame_id = self.frame_id
                packet = encoder.encode(jpeg, frame_id)
                threshold = (self.threshold + 1) & 255 if self.wrong_threshold else self.threshold
                packet = b'SPJ2' + packet[4:9] + bytes((threshold,)) + packet[9:]
                wire = bytearray()
                for at in range(0, len(packet), 1024):
                    flags = int(at == 0) | (2 if at + 1024 >= len(packet) else 0)
                    wire += block(0, struct.pack('<I', frame_id) + packet[at:at + 1024], flags)
                descriptor_id = frame_id + 1 if self.gap and index == 1 else frame_id
                # Descriptor IDs must match payload; a gap is valid framing but
                # invalid sequence, so rewrite both IDs for the changed frame.
                if descriptor_id != frame_id:
                    # The fixture is one MBLK payload block (under 1024 B).
                    struct.pack_into('<I', wire, 8, descriptor_id)
                timestamp = 1_000_000 + descriptor_id * 3_333_333
                wire += block(1, struct.pack('<7I', 0x4d4a1400, descriptor_id, timestamp, 0,
                                            len(packet), 64 | 8 << 16, 0))
                self.queue.append(bytes(wire))
                self.frame_id += 1
        elif command == b'S' and self.running:
            self.running = False
            self.queue.extend([block(5), self.camera()])
        return len(command)

    def flush(self):
        pass

    def read_chunk(self):
        self.clock.value += 0.025
        return self.queue.pop(0) if self.queue else b''

    def close(self):
        self.closed = True


class ThresholdSweepTests(unittest.TestCase):
    def make_runner(self, directory, **options):
        clock = MockClock()
        source = MockUSB(clock, **options)
        runner = ThresholdSweep(lambda: source, [0, 32, 255], 0.20, directory,
                                idle_timeout=1, stop_timeout=1, clock=clock)
        return runner, source

    def test_multiple_thresholds_capture_and_independent_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            runner, source = self.make_runner(directory)
            report = runner.run()
            self.assertTrue(report['passed'], report['error'])
            self.assertEqual(report['frames'], 9)
            self.assertEqual([item['threshold'] for item in report['phases']], [0, 32, 255])
            self.assertTrue(source.closed)
            self.assertEqual([command for command in source.writes if command.startswith(b'T')],
                             [b'T00\n', b'T20\n', b'TFF\n'])
            for phase in report['phases']:
                self.assertEqual((phase['starts'], phase['ends']), (1, 1))
                self.assertAlmostEqual(phase['median_fps'], 30.000003, places=5)
                self.assertEqual(phase['reused_groups'], 2)
                capture = Path(phase['directory']) / 'usb_capture.bin'
                self.assertEqual(capture.stat().st_size, phase['wire_bytes'])
                with capture.open('rb') as stream:
                    records = BlockRecords(stream.read)
                    decoded = 0
                    while True:
                        kind, value = records.next()
                        if kind == 'frame':
                            decoded += 1
                            self.assertEqual(records.spatial_stats['threshold'], phase['threshold'])
                        if kind == 'end':
                            break
                    self.assertEqual(decoded, 3)
                    self.assertEqual(stream.read(), b'')
                metadata = json.loads((Path(phase['directory']) / 'first_frame_metadata.json').read_text())
                self.assertEqual((metadata['width'], metadata['height'], metadata['format']), (64, 8, 'JPEG'))
            self.assertTrue((Path(directory) / 'THRESHOLD_SWEEP_PASS.txt').exists())

    def test_old_hardware_fails_before_any_threshold_command(self):
        with tempfile.TemporaryDirectory() as directory:
            runner, source = self.make_runner(directory, capable=False)
            report = runner.run()
            self.assertFalse(report['passed'])
            self.assertIn('lacks adjustable threshold', report['error'])
            self.assertFalse(any(command.startswith(b'T') for command in source.writes))
            self.assertEqual(source.writes[-2:], [b'S', b'l'])
            self.assertTrue(source.closed)

    def test_wrong_threshold_and_overflow_fail_and_cleanup(self):
        for options, message in ((dict(wrong_threshold=True), 'differs from requested'),
                                 (dict(overflow=True), 'FIFO overflow')):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                runner, source = self.make_runner(directory, **options)
                report = runner.run()
                self.assertFalse(report['passed'])
                self.assertIn(message, report['error'])
                self.assertEqual(source.writes[-2:], [b'S', b'l'])
                self.assertTrue(source.closed)
                self.assertFalse((Path(directory) / 'THRESHOLD_SWEEP_PASS.txt').exists())

    def test_missing_frame_id_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            runner, source = self.make_runner(directory, gap=True)
            report = runner.run()
            self.assertFalse(report['passed'])
            # SPJ2 reference validation can detect the skipped ID first.
            self.assertTrue('sequence' in report['error'] or 'gap' in report['error'])
            self.assertTrue(source.closed)

    def test_capture_can_be_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            runner, source = self.make_runner(directory)
            runner.capture = False
            report = runner.run()
            self.assertTrue(report['passed'], report['error'])
            self.assertFalse(list(Path(directory).rglob('*.bin')))

    def test_background_decode_errors_are_not_silently_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            runner, source = self.make_runner(directory)
            with patch('threshold_sweep._decode_jpeg', side_effect=ValueError('independent JPEG decode failed')):
                report = runner.run()
            self.assertFalse(report['passed'])
            self.assertIn('independent JPEG decode failed', report['error'])
            self.assertTrue(source.closed)
            self.assertEqual(source.writes[-2:], [b'S', b'l'])

    def test_threshold_parser_accepts_arbitrary_valid_values(self):
        self.assertEqual(parse_thresholds('0, 7,19,255'), [0, 7, 19, 255])
        for text in ('', '1,', '-1,0', '256', 'foo', '1.5'):
            with self.assertRaises(argparse.ArgumentTypeError):
                parse_thresholds(text)


if __name__ == '__main__':
    unittest.main()

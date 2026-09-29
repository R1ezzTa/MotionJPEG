"""Denoise capability, atomic command and preview reconnect lifecycle."""
import io
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from camera_viewer import PreviewWorker, denoise_command, parse_args
from block_records import BlockRecords
from test_camera_viewer import FakeDevice
from test_camera_receiver import block, frame_blocks, jpeg


def camera_status(strength=0, capable=True, revision=1):
    flags = 1 | (1 << 12) | (1 << 16) | (strength << 23)
    index = (0x1234 << 16) | ((1 << 10) if capable else 0) | ((1 << 11) if revision == 2 else 0) | 283
    return block(7, struct.pack('<8I', flags, (0x5678 << 16) | 0x5640, index, 0, 0, 0, 0, 0))


class DenoiseControlTests(unittest.TestCase):
    def test_revision_does_not_corrupt_index_or_frame_counter(self):
        for capable, revision, expected in ((True, 1, 1), (True, 2, 2), (False, 2, 0)):
            data = io.BytesIO(camera_status(255, capable, revision))
            kind, value = BlockRecords(data.read).next()
            self.assertEqual(kind, 'camera')
            self.assertEqual(value['denoise_revision'], expected)
            self.assertEqual(value['config_index'], 283)
            self.assertEqual(value['frame_sync_count'], 0x12345678)
            self.assertFalse(value['threshold_capable'])
            if capable:
                self.assertEqual(value['denoise_requested'], 255)

    def test_command_bounds_and_replay(self):
        self.assertEqual(denoise_command(0), b'N00\n')
        self.assertEqual(denoise_command(16), b'N10\n')
        self.assertEqual(denoise_command(207), b'NCF\n')
        for value in (-1, 256, True, 0.5):
            with self.assertRaises(ValueError):
                denoise_command(value)
        for argv in (['--denoise-strength', '-1'], ['--denoise-strength', '256'],
                     ['--capture', 'unused.bin', '--denoise-strength', '16']):
            with self.assertRaises(SystemExit):
                parse_args(argv)
        worker = PreviewWorker(parse_args(['--capture', 'unused.bin']))
        worker.update(denoise_capable=True)
        with self.assertRaises(ValueError):
            worker.set_denoise(16)

    def test_configuration_precedes_start_and_status_bit_is_independent(self):
        image = jpeg('red')
        data = camera_status() + block(6) + frame_blocks(0, 100, image) + block(5)
        device = FakeDevice(data, lambda: worker.stop.set())
        worker = PreviewWorker(parse_args(['--headless', '--duration', '2', '--auto-start', '--denoise-strength', '16']),
                               source_factory=lambda: device)
        worker.run()
        state = worker.snapshot()[1]
        self.assertIsNone(state['error'])
        self.assertEqual(device.sent, [b'N10\n', b'C', b'l', b'S'])
        self.assertTrue(state['camera']['denoise_capable'])
        self.assertFalse(state['camera']['threshold_capable'])
        self.assertFalse(state['camera']['adaptive_capable'])
        self.assertEqual(state['camera']['config_index'], 283)
        self.assertEqual(state['camera']['frame_sync_count'], 0x12345678)

    def test_unsupported_firmware_never_receives_start_or_denoise(self):
        device = FakeDevice(camera_status(capable=False))
        worker = PreviewWorker(parse_args(['--headless', '--duration', '2', '--auto-start', '--denoise-strength', '16']),
                               source_factory=lambda: device)
        worker.run()
        self.assertIn('requires firmware', worker.snapshot()[1]['error'])
        self.assertNotIn(b'C', device.sent)
        self.assertNotIn(b'N10\n', device.sent)

    def test_reconnect_restores_denoise_without_passive_start(self):
        image = jpeg('red')
        old = camera_status() + block(6) + frame_blocks(8, 900, image) + b'BADMAGIC'
        fresh = camera_status(32) + block(6) + frame_blocks(0, 100, image) + block(5)
        devices = [FakeDevice(old), FakeDevice(fresh, lambda: worker.stop.set())]
        opened = iter(devices)
        worker = PreviewWorker(parse_args(['--headless', '--duration', '3', '--denoise-strength', '32']),
                               source_factory=lambda: next(opened))
        worker.run()
        self.assertIsNone(worker.snapshot()[1]['error'])
        self.assertEqual(worker.snapshot()[1]['recoveries'], 1)
        self.assertEqual(devices[0].sent, [b'N20\n'])
        self.assertEqual(devices[1].sent, [b'N20\n', b'l', b'S'])
        self.assertEqual(worker.snapshot()[1]['camera']['denoise_requested'], 32)

    def test_live_command_is_capability_gated(self):
        worker = PreviewWorker(parse_args([]))
        with self.assertRaises(ValueError):
            worker.set_denoise(16)
        worker.update(denoise_capable=True)
        worker.set_denoise(16)
        self.assertEqual(worker.commands.get_nowait(), b'N10\n')
        self.assertEqual(worker.snapshot()[1]['denoise_requested'], 16)


if __name__ == '__main__':
    unittest.main()

"""Pure transition-state and mocked one-stream USB acceptance checks."""
import io
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from block_records import BlockRecords
from spatial_jpeg import SpatialEncoder
from threshold_live_change_test import LiveThresholdAcceptance, ThresholdTransitions
from test_spatial_coefficients import coefficient_jpeg, values
from test_threshold_sweep import MockClock, block


class LiveMockUSB:
    def __init__(self, clock, capable=True):
        self.clock, self.capable = clock, capable
        self.running = self.closed = False
        self.threshold = self.frame_id = 0
        self.encoder = SpatialEncoder()
        self.jpeg = coefficient_jpeg([values(dc=4)])
        self.writes = []
        self.queue = [self.camera()]

    def camera(self):
        flags = 1 | 1 << 14 | 1 << 15 | 1 << 16 | 2 << 18 | 2 << 20
        if self.capable:
            flags |= 1 << 31
        return block(7, struct.pack('<8I', flags, 0x5640, 0, 0, 0, 0, 0, 0))

    def frame(self):
        frame_id = self.frame_id
        packet = self.encoder.encode(self.jpeg, frame_id)
        packet = b'SPJ2' + packet[4:9] + bytes((self.threshold,)) + packet[9:]
        wire = block(0, struct.pack('<I', frame_id) + packet, 3)
        wire += block(1, struct.pack('<7I', 0x4d4a1400, frame_id,
                                    100_000 + frame_id * 3_333_333, 0, len(packet), 64 | 8 << 16, 0))
        self.frame_id += 1
        return wire

    def write(self, value):
        self.writes.append(value)
        if value.startswith(b'T'):
            threshold = int(value[1:3], 16)
            if self.running:
                # A frame already in USB retains the old threshold after T.
                self.queue.append(self.frame())
            if threshold != self.threshold:
                self.encoder = SpatialEncoder()
            self.threshold = threshold
        elif value == b'C':
            self.running = True
            self.queue.append(block(6))
        elif value == b'S' and self.running:
            self.running = False
            self.queue.extend((block(5), self.camera()))
        return len(value)

    def flush(self):
        pass

    def read_chunk(self):
        self.clock.value += 0.025
        if self.queue:
            return self.queue.pop(0)
        return self.frame() if self.running else b''

    def close(self):
        self.closed = True


class ThresholdTransitionTests(unittest.TestCase):
    def test_changed_threshold_waits_for_old_frames_and_requires_keyframe(self):
        state = ThresholdTransitions([0, 32], 2)
        state.request(0, None, 0)
        self.assertEqual(state.accept(0, 0, True, 0.1), 0)
        state.accept(1, 0, False, 0.2)
        self.assertTrue(state.phase_complete)
        state.request(1, 1, 0.2)
        self.assertIsNone(state.accept(2, 0, False, 0.3))
        self.assertIsNone(state.accept(3, 0, False, 0.4))
        with self.assertRaisesRegex(ValueError, 'keyframe'):
            state.accept(4, 32, False, 0.5)
        self.assertEqual(state.accept(4, 32, True, 0.5), 1)
        self.assertEqual(state.history[1]['old_inflight_frames'], 2)
        self.assertEqual(state.history[1]['first_frame_id'], 4)

    def test_repeated_threshold_does_not_require_new_keyframe(self):
        state = ThresholdTransitions([32, 32], 1)
        state.request(0, None, 0)
        state.accept(0, 32, True, 0.1)
        state.request(1, 0, 0.2)
        self.assertEqual(state.accept(1, 32, False, 0.3), 1)
        self.assertFalse(state.history[1]['first_frame_keyframe'])

    def test_unrequested_threshold_and_transition_bound_rejected(self):
        state = ThresholdTransitions([0, 64], 1, max_transition_frames=1)
        state.request(0, None, 0)
        state.accept(0, 0, True, 0.1)
        with self.assertRaisesRegex(ValueError, 'without a command'):
            state.accept(1, 32, True, 0.2)
        state.request(1, 0, 0.2)
        with self.assertRaisesRegex(ValueError, 'Unexpected'):
            state.accept(1, 32, True, 0.3)
        state.accept(1, 0, False, 0.3)
        with self.assertRaisesRegex(ValueError, 'frame bound'):
            state.accept(2, 0, False, 0.4)

    def test_full_continuous_mock_stream_and_capture_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            clock = MockClock()
            source = LiveMockUSB(clock)
            runner = LiveThresholdAcceptance(lambda: source, [0, 32, 32, 64, 0], directory,
                                             frames_per_threshold=3, clock=clock)
            report = runner.run()
            self.assertTrue(report['passed'], report['error'])
            self.assertEqual((report['starts'], report['ends']), (1, 1))
            self.assertEqual([phase['threshold'] for phase in report['transitions']], [0, 32, 32, 64, 0])
            self.assertEqual([phase['old_inflight_frames'] for phase in report['transitions']], [0, 1, 0, 1, 1])
            self.assertFalse(report['transitions'][2]['first_frame_keyframe'])
            self.assertEqual(source.writes.count(b'C'), 1)
            self.assertTrue(source.closed)
            self.assertEqual(len(list(Path(directory).glob('sample_*.jpg'))), 3)
            with (Path(directory) / 'usb_capture.bin').open('rb') as capture:
                records = BlockRecords(capture.read)
                starts = ends = frames = 0
                while not ends:
                    kind, _ = records.next()
                    starts += kind == 'start'
                    ends += kind == 'end'
                    frames += kind == 'frame'
                self.assertEqual((starts, ends, frames), (1, 1, report['frames']))
                self.assertEqual(capture.tell(), report['wire_bytes'])
                self.assertEqual(capture.read(), b'')

    def test_old_firmware_stops_before_any_threshold_command(self):
        with tempfile.TemporaryDirectory() as directory:
            clock = MockClock()
            source = LiveMockUSB(clock, capable=False)
            report = LiveThresholdAcceptance(lambda: source, [0, 32], directory, 2, clock=clock).run()
            self.assertFalse(report['passed'])
            self.assertFalse(any(value.startswith(b'T') for value in source.writes))
            self.assertTrue(source.closed)
            self.assertEqual(source.writes[-2:], [b'S', b'l'])

    def test_rejected_sensor_frames_are_not_hidden_by_median_rate(self):
        class DroppedSensorUSB(LiveMockUSB):
            def frame(self):
                wire = super().frame()
                # Frame IDs remain contiguous even though sensor frames are lost.
                sensor_id = self.frame_id - 1 + (self.frame_id - 1) // 5
                timestamp = 100_000 + sensor_id * 3_333_333
                descriptor_offset = len(wire) - 28
                return (wire[:descriptor_offset + 8] + struct.pack('<I', timestamp)
                        + wire[descriptor_offset + 12:])

        with tempfile.TemporaryDirectory() as directory:
            clock = MockClock()
            source = DroppedSensorUSB(clock)
            report = LiveThresholdAcceptance(lambda: source, [64], directory, 20, clock=clock).run()
            self.assertFalse(report['passed'])
            self.assertAlmostEqual(report['median_fps'], 30, places=4)
            self.assertLess(report['mean_fps'], 29)
            self.assertIn('Camera rate', report['error'])
            self.assertTrue(source.closed)


if __name__ == '__main__':
    unittest.main()

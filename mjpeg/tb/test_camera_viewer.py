"""Viewer-specific streaming lifecycle and bounded-preview checks."""
import io
import struct
import sys
import threading
import time
import unittest
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from camera_viewer import PreviewPreparation, PreviewWorker, decode_frame, parse_args
from test_camera_receiver import block, frame_blocks, jpeg


class FakeDevice:
    def __init__(self, data, on_empty=None):
        self.data, self.offset = data, 0
        self.on_empty = on_empty
        self.sent = []
        self.closed = False

    def write(self, command):
        self.sent.append(command)

    def flush(self):
        pass

    def read_chunk(self):
        value = self.data[self.offset:self.offset + 37]
        self.offset += len(value)
        if not value and self.on_empty:
            self.on_empty()
        return value

    def close(self):
        self.closed = True


class CameraViewerTests(unittest.TestCase):


    @staticmethod
    def camera_status():
        return block(7, struct.pack('<8I', 1, 0x5640, 277, 0, 0, 0, 0, 0))

    def test_pc_stop_keeps_connection_and_allows_another_start(self):
        image = jpeg('red')

        def status(running):
            flags = 1 | (1 << 16) | (1 << 31)
            if running:
                flags |= (1 << 17) | (1 << 6)
            return block(7, struct.pack('<8I', flags, 0x5640, 283, 0, 0, 0, 0, 0))

        class ControlledDevice:
            def __init__(self):
                self.buffer = bytearray(status(False))
                self.sent = []
                self.closed = self.running = False
                self.frame_id = self.step = 0
                self.idle_after_stop = []

            def write(self, command):
                self.sent.append(command)
                if command == b'C' and not self.running:
                    self.running = True
                    self.buffer.extend(block(6) + frame_blocks(
                        self.frame_id, 100 + self.frame_id * 100_000_000, image) + status(True))
                    self.frame_id += 1
                elif command == b'S' and self.running:
                    self.running = False
                    self.buffer.extend(block(5) + status(False))

            def flush(self):
                pass

            def read_chunk(self):
                if not self.buffer:
                    if self.step in (0, 2):
                        if self.step == 2:
                            self.idle_after_stop.append(worker.snapshot()[1]['phase'])
                            self.idle_after_stop.append(worker.stop.is_set())
                        worker.set_transmission(True)
                    elif self.step in (1, 3):
                        worker.set_transmission(False)
                    else:
                        worker.stop.set()
                    self.step += 1
                    return b''
                value = bytes(self.buffer[:37])
                del self.buffer[:37]
                return value

            def close(self):
                self.closed = True

        device = ControlledDevice()
        worker = PreviewWorker(parse_args(['--headless', '--duration', '2']), source_factory=lambda: device)
        worker.run()
        state = worker.snapshot()[1]
        self.assertIsNone(state['error'])
        self.assertEqual(state['decoded'], 2)
        self.assertEqual(state['recoveries'], 0)
        self.assertEqual(device.idle_after_stop, ['waiting', False])
        self.assertEqual(device.sent, [b'C', b'S', b'C', b'S', b'l', b'S'])
        self.assertFalse(state['camera']['run_requested'])
        self.assertTrue(device.closed)

    def test_pc_transmission_control_rejects_replay_and_unready_connection(self):
        for args in (parse_args([]), parse_args(['--capture', 'unused.bin'])):
            worker = PreviewWorker(args)
            for enabled in (True, False):
                with self.assertRaises(ValueError):
                    worker.set_transmission(enabled)
            self.assertTrue(worker.commands.empty())

    def replay(self, data):
        args = parse_args(['--capture', 'unused.bin', '--headless'])
        worker = PreviewWorker(args, source_factory=lambda: io.BytesIO(data))
        worker.run()
        return worker

    def test_long_replay_retains_latest_frame_without_a_frame_queue(self):
        image = jpeg('green')
        data = block(6)
        for index in range(80):
            data += block(2, struct.pack('<5I', index + 1, 1, 1, 0, index + 1))
            data += frame_blocks(index, index * 3_333_333, image)
        worker = self.replay(data + block(5))
        latest, state = worker.snapshot()
        self.assertIsNone(state['error'])
        self.assertEqual(state['phase'], 'finished')
        self.assertEqual((state['received'], state['decoded']), (80, 80))
        self.assertEqual(latest[1].frame_id, 79)
        self.assertEqual(latest[1].jpeg, image)
        self.assertEqual(state['rate']['window'], 80)

    def test_stop_mid_record_drains_frame_and_end_before_closing_device(self):
        image = jpeg('red')
        data = block(6) + frame_blocks(0, 0, image) + block(5)

        class Device:
            def __init__(self):
                self.offset = self.reads = 0
                self.sent = []
                self.closed = False

            def write(self, command):
                self.sent.append(command)

            def flush(self):
                pass

            def read_chunk(self):
                self.reads += 1
                if self.reads == 3:
                    worker.stop.set()
                value = data[self.offset:self.offset + 11]
                self.offset += len(value)
                return value

            def close(self):
                self.closed = True

        device = Device()
        worker = PreviewWorker(parse_args(['--headless', '--duration', '1', '--auto-start']),
                               source_factory=lambda: device)
        worker.run()
        latest, state = worker.snapshot()
        self.assertIsNone(state['error'])
        self.assertEqual(latest[1].jpeg, image)
        self.assertEqual(state['decoded'], 1)
        self.assertEqual(device.offset, len(data))
        self.assertEqual(device.sent, [b'C', b'l', b'S'])
        self.assertTrue(device.closed)

    def test_replay_multiple_board_start_stop_sessions(self):
        image = jpeg('red')
        data = b''
        for index in range(3):
            data += block(6) + frame_blocks(index, index * 3_333_333, image) + block(5)
        worker = self.replay(data)
        latest, state = worker.snapshot()
        self.assertIsNone(state['error'])
        self.assertEqual(state['phase'], 'finished')
        self.assertEqual((state['received'], state['decoded']), (3, 3))
        self.assertEqual(latest[1].frame_id, 2)

    def test_passive_live_waits_after_end_and_can_close_while_idle(self):
        image = jpeg('red')
        data = (block(6) + frame_blocks(0, 0, image) + block(5) +
                block(6) + frame_blocks(1, 100_000_000, image) + block(5))

        class Device:
            def __init__(self):
                self.sent = []
                self.offset = 0
                self.closed = False
            def write(self, command):
                self.sent.append(command)
            def flush(self):
                pass
            def read_chunk(self):
                if self.offset == len(data):
                    worker.stop.set()
                    return b''
                value = data[self.offset:self.offset + 13]
                self.offset += len(value)
                return value
            def close(self):
                self.closed = True

        device = Device()
        worker = PreviewWorker(parse_args(['--headless', '--duration', '1']), source_factory=lambda: device)
        worker.run()
        self.assertIsNone(worker.snapshot()[1]['error'])
        self.assertEqual(worker.snapshot()[1]['decoded'], 2)
        self.assertEqual(device.sent, [b'l', b'S'])
        self.assertTrue(device.closed)

    def test_truncated_capture_and_corrupt_jpeg_report_errors(self):
        data = block(6) + frame_blocks(0, 0, jpeg('red'))
        self.assertIn('EOFError', self.replay(data).snapshot()[1]['error'])
        invalid = b'\xff\xd8not-a-jpeg\xff\xd9'
        data = block(6) + frame_blocks(0, 0, invalid) + block(5)
        self.assertIsNotNone(self.replay(data).snapshot()[1]['error'])

    def test_preview_accepts_actual_resolution_and_rejects_descriptor_mismatch(self):
        worker = self.replay(block(6) + frame_blocks(0, 0, jpeg('blue', 32, 16), 32, 16) + block(5))
        frame = worker.snapshot()[0][1]
        with decode_frame(frame) as image:
            self.assertEqual(image.size, (32, 16))
        worker = self.replay(block(6) + frame_blocks(0, 0, jpeg('blue'), 32, 16) + block(5))
        self.assertIn('dimensions', worker.snapshot()[1]['error'])

    def test_live_reset_in_partial_jpeg_reopens_and_accepts_frame_zero(self):
        image = jpeg('red')
        # One complete frame, then a started but unfinished frame. RESET cuts
        # a following block header in half; its remaining bytes are new status.
        partial = block(0, struct.pack('<I', 18) + image[:150], flags=1)
        old = block(6) + frame_blocks(17, 900_000_000, image) + partial + b'MBL\0BROK'
        fresh = (block(2, struct.pack('<5I', 1, 1, 1, 0, 1)) + block(6) +
                 frame_blocks(0, 100, image) + block(5))
        devices = [FakeDevice(old), FakeDevice(fresh, lambda: worker.stop.set())]
        opened = []
        def factory():
            device = devices[len(opened)]
            opened.append(device)
            return device
        worker = PreviewWorker(parse_args(['--headless', '--duration', '3']), source_factory=factory)
        worker.run()
        latest, state = worker.snapshot()
        self.assertIsNone(state['error'])
        self.assertEqual((state['received'], state['decoded'], state['recoveries']), (2, 2, 1))
        self.assertEqual(state['discarded_partial_frames'], 1)
        self.assertEqual(latest[1].frame_id, 0)
        self.assertEqual(state['rate']['window'], 1)
        self.assertIn('Invalid block header', state['last_recovery'])
        self.assertEqual(state['connection_epoch'], 1)
        self.assertTrue(all(device.closed for device in devices))
        self.assertFalse(devices[0].sent)  # No STOP that changes board key selection during recovery.
        self.assertNotIn(b'C', devices[1].sent)  # Reconnect remains passive.

    def test_aligned_idle_reset_fps_regression_recovers_without_an_image(self):
        old = (block(2, struct.pack('<5I', 50, 0, 0, 0, 300)) +
               block(2, struct.pack('<5I', 1, 0, 0, 0, 0)))
        fresh = block(2, struct.pack('<5I', 1, 0, 0, 0, 0))
        devices = [FakeDevice(old), FakeDevice(fresh, lambda: worker.stop.set())]
        index = iter(devices)
        worker = PreviewWorker(parse_args(['--headless', '--duration', '3']), source_factory=lambda: next(index))
        worker.run()
        latest, state = worker.snapshot()
        self.assertIsNone(state['error'])
        self.assertIsNone(latest)
        self.assertEqual((state['recoveries'], state['received']), (1, 0))
        self.assertIn('FPS sequence', state['last_recovery'])
        self.assertEqual(state['rate']['window'], 1)

    def test_persistent_bad_transport_has_bounded_retries(self):
        devices = []
        def factory():
            device = FakeDevice(b'BADMAGIC')
            devices.append(device)
            return device
        worker = PreviewWorker(parse_args(['--headless', '--duration', '3']), source_factory=factory)
        worker.run()
        self.assertEqual(len(devices), 4)
        self.assertEqual(worker.snapshot()[1]['recoveries'], 3)
        self.assertIn('Invalid block header', worker.snapshot()[1]['error'])
        self.assertTrue(all(device.closed for device in devices))


class PreviewPreparationTests(unittest.TestCase):
    def start_preparation(self, decoder):
        preparation = PreviewPreparation(decoder)
        preparation.start()

        def cleanup():
            preparation.close()
            preparation.join(2)
            self.assertFalse(preparation.is_alive())

        self.addCleanup(cleanup)
        return preparation

    def wait_for(self, predicate):
        deadline = time.monotonic() + 2
        while not predicate() and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertTrue(predicate(), 'Preview preparation did not complete')

    def assert_closed(self, image):
        with self.assertRaises(ValueError):
            image.getpixel((0, 0))

    def test_slow_decode_replaces_waiting_frames_and_fits_preview(self):
        began, release = threading.Event(), threading.Event()
        calls, images, thread_ids = [], [], []

        def decoder(frame):
            calls.append(frame)
            thread_ids.append(threading.get_ident())
            if frame == 'first':
                began.set()
                if not release.wait(2):
                    raise TimeoutError('Test decoder was not released')
            image = Image.new('RGB', (80, 40), 'blue')
            images.append(image)
            return image

        preparation = self.start_preparation(decoder)
        self.addCleanup(release.set)
        preparation.submit(1, 'first', (40, 40), 0)
        self.assertTrue(began.wait(2))
        preparation.submit(2, 'superseded', (40, 40), 0)
        preparation.submit(3, 'latest', (40, 40), 0)
        release.set()
        self.wait_for(lambda: preparation.latest is not None and preparation.latest[0] == 3)
        number, frame, bounds, epoch, image = preparation.take()
        self.addCleanup(image.close)
        self.assertEqual((number, frame, bounds, epoch), (3, 'latest', (40, 40), 0))
        self.assertEqual(calls, ['first', 'latest'])
        self.assertEqual(image.size, (40, 20))
        self.assertTrue(all(x != threading.get_ident() for x in thread_ids))
        self.assert_closed(images[0])

    def test_reconnect_discards_inflight_old_image(self):
        began, release = threading.Event(), threading.Event()
        images = []

        def decoder(frame):
            if frame == 'old':
                began.set()
                if not release.wait(2):
                    raise TimeoutError('Test decoder was not released')
            image = Image.new('RGB', (8, 4))
            images.append(image)
            return image

        preparation = self.start_preparation(decoder)
        self.addCleanup(release.set)
        preparation.submit(9, 'old', None, 0)
        self.assertTrue(began.wait(2))
        preparation.clear()
        preparation.submit(10, 'new', None, 1)
        release.set()
        self.wait_for(lambda: preparation.latest is not None)
        result = preparation.take()
        self.addCleanup(result[-1].close)
        self.assertEqual((result[0], result[1], result[3]), (10, 'new', 1))
        self.assert_closed(images[0])
        self.assertIsNone(preparation.error)

    def test_error_from_old_connection_does_not_stop_new_preparation(self):
        began, release = threading.Event(), threading.Event()

        def decoder(frame):
            if frame == 'old':
                began.set()
                if not release.wait(2):
                    raise TimeoutError('Test decoder was not released')
                raise OSError('Obsolete JPEG')
            return Image.new('RGB', (8, 4))

        preparation = self.start_preparation(decoder)
        self.addCleanup(release.set)
        preparation.submit(1, 'old', None, 0)
        self.assertTrue(began.wait(2))
        preparation.clear()
        preparation.submit(2, 'new', None, 1)
        release.set()
        self.wait_for(lambda: preparation.latest is not None or preparation.error is not None)
        self.assertIsNone(preparation.error)
        self.assertTrue(preparation.is_alive())
        result = preparation.take()
        self.addCleanup(result[-1].close)
        self.assertEqual(result[1], 'new')

    def test_current_decode_error_is_reported_and_stops_thread(self):
        def decoder(frame):
            raise ValueError('Malformed JPEG')

        preparation = self.start_preparation(decoder)
        preparation.submit(1, 'bad', None, 0)
        self.wait_for(lambda: not preparation.is_alive())
        self.assertEqual(preparation.error, 'ValueError: Malformed JPEG')
        self.assertIsNone(preparation.take())

    def test_closing_during_decode_closes_the_late_image(self):
        began, release = threading.Event(), threading.Event()
        image = Image.new('RGB', (8, 4))
        self.addCleanup(image.close)

        def decoder(frame):
            began.set()
            if not release.wait(2):
                raise TimeoutError('Test decoder was not released')
            return image

        preparation = self.start_preparation(decoder)
        self.addCleanup(release.set)
        preparation.submit(1, 'pending', None, 0)
        self.assertTrue(began.wait(2))
        preparation.close()
        release.set()
        preparation.join(2)
        self.assertFalse(preparation.is_alive())
        self.assertIsNone(preparation.take())
        self.assert_closed(image)

    def test_clear_closes_unconsumed_result(self):
        image = Image.new('RGB', (8, 4))
        self.addCleanup(image.close)
        preparation = self.start_preparation(lambda frame: image)
        preparation.submit(1, 'ready', None, 0)
        self.wait_for(lambda: preparation.latest is not None)
        preparation.clear()
        self.assertIsNone(preparation.take())
        self.assert_closed(image)


if __name__ == '__main__':
    unittest.main()

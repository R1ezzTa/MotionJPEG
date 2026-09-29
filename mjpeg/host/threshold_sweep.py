"""Test adjustable spatial-skip thresholds on the FPGA over exclusive USB.

Each threshold starts a fresh stream and saves its first reconstructed JPEG,
per-frame metrics, and (by default) a complete MBLK capture. Close the preview
window before running: this process must be the only USB_SLAVE reader.
Thresholds are dequantized DCT units, not pixel brightness units.
"""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import io
import json
from pathlib import Path
import statistics
import time

from PIL import Image

from block_records import BlockRecords
from camera_viewer import d2xx_library, threshold_command, adaptive_command
from ftdi_fifo import FtdiFifo


def parse_thresholds(text):
    try:
        values = [int(value.strip()) for value in text.split(',')]
    except ValueError as error:
        raise argparse.ArgumentTypeError('Thresholds must be comma-separated integers, 0–255') from error
    if not values or any(not 0 <= value <= 255 for value in values):
        raise argparse.ArgumentTypeError('Thresholds must be comma-separated integers, 0–255')
    return values


def _decode_jpeg(data, expected_size):
    with Image.open(io.BytesIO(data)) as image:
        if image.format != 'JPEG' or image.size != expected_size:
            raise ValueError('JPEG dimensions differ from the descriptor')
        image.load()


def _quality_table(level):
    values = [int(line, 16) & 255 for line in
              (Path(__file__).resolve().parents[1] / 'data/board_test/camera_quant.mem').read_text().splitlines()]
    offset = (level - 1) * 128
    return {0: values[offset:offset + 64], 1: values[offset + 64:offset + 128]}


class ThresholdSweep:
    """Testable sweep runner; ``source_factory`` opens one exclusive USB source."""
    def __init__(self, source_factory, thresholds, seconds, output, quality=3,
                 capture=True, core_clock_hz=100_000_000, idle_timeout=10,
                 stop_timeout=5, clock=time.monotonic, adaptive=None):
        if not thresholds or any(isinstance(x, bool) or not isinstance(x, int) or not 0 <= x <= 255 for x in thresholds):
            raise ValueError('Thresholds must be integers from 0 to 255')
        if not seconds > 0 or quality not in (1, 2, 3) or not core_clock_hz > 0:
            raise ValueError('Invalid duration, quality or core clock')
        self.source_factory = source_factory
        self.thresholds = thresholds
        self.seconds = seconds
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.quality = quality
        self.adaptive = adaptive
        self.expected_quality_table = _quality_table(quality)
        self.capture = capture
        self.core_clock_hz = core_clock_hz
        self.idle_timeout = idle_timeout
        self.stop_timeout = stop_timeout
        self.clock = clock
        self.source = self.records = self.capture_file = None
        self.buffer = bytearray()
        self.actions = []
        self.phases = []
        self.frames = []
        self.camera_status = []
        self.active = None
        self.next_phase = 0
        self.expected_id = self.previous_tick = None
        self.pending = deque()
        self.pool = None
        self.usb_read_bytes = 0

    def command(self, value):
        self.source.write(value)
        self.source.flush()
        self.actions.append(dict(seconds=self.clock() - self.began, command=value.decode('ascii')))

    def check_control(self):
        now = self.clock()
        if now - self.last_data > self.idle_timeout:
            raise TimeoutError('No USB data; check board power and USB_SLAVE')
        if self.active:
            phase = self.active
            if phase['start_wall'] is None:
                if now - phase['requested_wall'] > self.idle_timeout:
                    raise TimeoutError('No START after C')
            elif phase['stop_wall'] is None and now - phase['start_wall'] >= self.seconds:
                self.command(b'S')
                phase['stop_wall'] = now
            elif phase['stop_wall'] is not None and now - phase['stop_wall'] > self.stop_timeout:
                raise TimeoutError('No END after S')
        elif now - self.waiting_since > self.idle_timeout:
            raise TimeoutError('Camera did not become ready and stopped')

    def exact(self, count):
        self.check_control()
        while len(self.buffer) < count:
            self.check_control()
            data = self.source.read_chunk()
            if data:
                self.last_data = self.clock()
                self.usb_read_bytes += len(data)
                self.buffer.extend(data)
        value = bytes(self.buffer[:count])
        del self.buffer[:count]
        # Write the exact consumed bytes, rather than native USB read-ahead, so
        # each file ends at its own END and can be replayed independently.
        if self.capture_file is not None:
            self.capture_file.write(value)
        return value

    def start_phase(self):
        threshold = self.thresholds[self.next_phase]
        directory = self.output / f'{self.next_phase:02d}_threshold_{threshold:03d}'
        directory.mkdir(parents=True, exist_ok=True)
        phase = dict(threshold=threshold, index=self.next_phase,
                     requested_wall=self.clock(), start_wall=None, stop_wall=None,
                     directory=str(directory.resolve()), frames=[], wire_begin=self.records.wire_bytes,
                     starts=0, ends=0)
        self.active = phase
        self.command(str(self.quality).encode('ascii'))
        self.command(threshold_command(threshold))
        if self.adaptive is not None:
            self.command(adaptive_command(self.adaptive))
        if self.capture:
            self.capture_file = (directory / 'usb_capture.bin').open('wb')
        self.command(b'C')

    def finish_phase(self):
        phase = self.active
        if phase['stop_wall'] is None:
            raise ValueError('Stream ended before the requested sweep duration')
        if not phase['frames']:
            raise ValueError('Threshold phase produced no frames')
        while self.pending:
            self.pending.popleft().result()
        if self.capture_file is not None:
            self.capture_file.close()
            self.capture_file = None
        frames = phase['frames']
        deltas = [b['timestamp'] - a['timestamp'] for a, b in zip(frames, frames[1:])]
        fps = self.core_clock_hz / statistics.median(deltas) if deltas else 0
        mean_fps = self.core_clock_hz / statistics.mean(deltas) if deltas else 0
        payload = sum(frame['transport_payload_bytes'] for frame in frames)
        restored = sum(frame['reconstructed_jpeg_bytes'] for frame in frames)
        elapsed = self.clock() - phase['start_wall']
        summary = dict(index=phase['index'], threshold=phase['threshold'], adaptive=frames[0]['adaptive'],
                       frames=len(frames), decoded_frames=len(frames), starts=phase['starts'], ends=phase['ends'],
                       median_fps=fps,
                       mean_fps=mean_fps,
                       duration_seconds=elapsed, transport_payload_bytes=payload,
                       reconstructed_jpeg_bytes=restored, payload_vs_reconstructed_ratio=payload / restored,
                       payload_mb_per_second=payload / len(frames) * mean_fps / 1_000_000,
                       wire_bytes=self.records.wire_bytes - phase['wire_begin'],
                       wire_mb_per_second=(self.records.wire_bytes - phase['wire_begin']) / elapsed / 1_000_000,
                       reused_groups=sum(frame['reused_groups'] for frame in frames),
                       total_groups=sum(frame['groups'] for frame in frames),
                       keyframes=sum(frame['keyframe'] for frame in frames),
                       camera_fifo_overflows=0, directory=phase['directory'])
        directory = Path(phase['directory'])
        (directory / 'frames.json').write_text(json.dumps(frames, indent=2) + '\n', encoding='utf-8')
        (directory / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
        self.phases.append(summary)
        print(f"Threshold {phase['threshold']:3d}: {len(frames)} frames, {mean_fps:.4f} fps, "
              f"reused {summary['reused_groups']}/{summary['total_groups']}, "
              f"payload {summary['payload_mb_per_second']:.3f} MB/s", flush=True)
        self.active = None
        self.next_phase += 1
        self.waiting_since = self.clock()

    def accept_frame(self, frame):
        if frame.status or frame.jpeg is None:
            raise ValueError(f'Frame {frame.frame_id} failed, status={frame.status}')
        if self.expected_id is not None and frame.frame_id != self.expected_id:
            raise ValueError(f'Frame sequence gap: expected {self.expected_id}, got {frame.frame_id}')
        if self.previous_tick is not None and frame.timestamp <= self.previous_tick:
            raise ValueError('Frame timestamp did not increase')
        self.expected_id = (frame.frame_id + 1) & 0xffffffff
        self.previous_tick = frame.timestamp
        if self.active is None:
            return  # Drain an already-running session before the first phase.
        phase = self.active
        stats = self.records.spatial_stats
        if not stats or stats.get('frame_id') != frame.frame_id or 'threshold' not in stats:
            raise ValueError('Expected SPJ2 adjustable-threshold frame')
        if stats['threshold'] != phase['threshold']:
            raise ValueError(f"Frame threshold {stats['threshold']} differs from requested {phase['threshold']}")
        if self.adaptive is not None and stats.get('adaptive', False) != self.adaptive:
            raise ValueError('Frame adaptive mode differs from the requested mode')
        if not phase['frames'] and not stats['keyframe']:
            raise ValueError('Fresh START did not produce a full reference keyframe')
        if phase['start_wall'] is None:
            raise ValueError('Frame arrived before START')
        size = (frame.width, frame.height)
        with Image.open(io.BytesIO(frame.jpeg)) as image:
            if image.format != 'JPEG' or image.size != size:
                raise ValueError('JPEG dimensions differ from the descriptor')
            if image.quantization != self.expected_quality_table:
                raise ValueError('JPEG does not use the requested complete quality table')
            sample_metadata = dict(format=image.format, width=image.width, height=image.height,
                                   bytes=len(frame.jpeg), quality=(60, 75, 85)[self.quality - 1])
        self.pending.append(self.pool.submit(_decode_jpeg, frame.jpeg, size))
        while self.pending and (self.pending[0].done() or len(self.pending) >= 64):
            self.pending.popleft().result()
        if not phase['frames']:
            directory = Path(phase['directory'])
            (directory / 'first_frame.jpg').write_bytes(frame.jpeg)
            (directory / 'first_frame_metadata.json').write_text(json.dumps(sample_metadata, indent=2) + '\n', encoding='utf-8')
        item = dict(frame_id=frame.frame_id, timestamp=frame.timestamp, threshold=phase['threshold'],
                    adaptive=stats.get('adaptive', False),
                    width=frame.width, height=frame.height, status=frame.status,
                    transport_payload_bytes=stats['transport_bytes'], reconstructed_jpeg_bytes=len(frame.jpeg),
                    reused_groups=stats['reused'], groups=stats['groups'], keyframe=stats['keyframe'])
        phase['frames'].append(item)
        self.frames.append(item)

    def run(self):
        Image.init()
        self.began = self.last_data = self.waiting_since = self.clock()
        error = None
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix='threshold-jpeg')
        try:
            self.source = self.source_factory()
            self.records = BlockRecords(self.exact)
            # Stop any retained RUN request. Never purge a live MBLK stream.
            self.command(b'l')
            self.command(b'S')
            while self.next_phase < len(self.thresholds):
                kind, value = self.records.next()
                if kind == 'camera':
                    self.camera_status.append(value.copy())
                    if not value.get('threshold_capable'):
                        raise ValueError('Firmware lacks adjustable threshold support; no threshold command was sent')
                    if self.adaptive is not None and not value.get('adaptive_capable'):
                        raise ValueError('Firmware lacks board adaptive mode support')
                    if not value.get('board_controls'):
                        raise ValueError('Firmware lacks board controls')
                    if any(value[name] for name in ('init_error', 'config_error', 'light_error')):
                        raise ValueError(f'Camera/controller error: {value}')
                    if value['overflow_count']:
                        raise ValueError(f"Camera FIFO overflow count {value['overflow_count']}")
                    if self.active is None and value['init_done'] and value.get('sampling_ready') and not value['streaming'] and not value['run_requested'] and not self.records.in_stream:
                        self.start_phase()
                elif kind == 'start' and self.active is not None:
                    if self.active['starts']:
                        raise ValueError('Duplicate START in threshold phase')
                    self.active['starts'] += 1
                    self.active['start_wall'] = self.clock()
                elif kind == 'frame':
                    self.accept_frame(value)
                elif kind == 'end' and self.active is not None:
                    self.active['ends'] += 1
                    if self.active['starts'] != 1:
                        raise ValueError('END without phase START')
                    self.finish_phase()
                for history in (self.records.rates, self.records.timings, self.records.links, self.records.camera_status):
                    if len(history) > 2:
                        del history[:-2]
            # Check a stopped camera snapshot after the last END, so its final
            # overflow counter and RUN/light state cannot escape verification.
            stopped = False
            while not stopped:
                kind, value = self.records.next()
                if kind == 'frame' or kind == 'start':
                    raise ValueError('Unexpected stream after final END')
                if kind == 'camera':
                    self.camera_status.append(value.copy())
                    if value['overflow_count'] or any(value[name] for name in ('init_error', 'config_error', 'light_error')):
                        raise ValueError(f'Final camera/controller error: {value}')
                    stopped = not value['streaming'] and not value['run_requested'] and not value['light_on']
        except Exception as exc:
            error = f'{type(exc).__name__}: {exc}'
        finally:
            if self.source is not None:
                for value in (b'S', b'l'):
                    try:
                        self.command(value)
                    except Exception as exc:
                        error = error or f'Cleanup failed: {exc}'
                try:
                    self.source.close()
                except Exception as exc:
                    error = error or f'Close failed: {exc}'
            if self.capture_file is not None:
                self.capture_file.close()
                self.capture_file = None
            while self.pending:
                try:
                    self.pending.popleft().result()
                except Exception as exc:
                    error = error or f'JPEG decode failed: {exc}'
            self.pool.shutdown(wait=True)
        report = dict(passed=error is None, error=error, thresholds=self.thresholds,
                      adaptive=self.adaptive,
                      seconds_per_threshold=self.seconds, quality=(60, 75, 85)[self.quality - 1],
                      threshold_units='maximum absolute dequantized DCT coefficient difference',
                      phases=self.phases, frames=len(self.frames), actions=self.actions,
                      usb_read_bytes=self.usb_read_bytes, capture_enabled=self.capture,
                      physical_buttons_tested=False,
                      note='Payload/restored-JPEG ratio is not a same-input comparison against ordinary MJPEG.')
        (self.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        (self.output / 'frames.json').write_text(json.dumps(self.frames, indent=2) + '\n', encoding='utf-8')
        (self.output / 'camera_status.json').write_text(json.dumps(self.camera_status, indent=2) + '\n', encoding='utf-8')
        if error is None:
            (self.output / 'THRESHOLD_SWEEP_PASS.txt').write_text('All thresholds matched SPJ2 frames; complete independent JPEG decode, START/END refresh, sequence and zero-overflow checks passed.\n', encoding='utf-8')
        return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--thresholds', type=parse_thresholds, default=parse_thresholds('0,8,16,32,64,128,255'))
    parser.add_argument('--seconds', type=float, default=3)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--quality', type=int, choices=(1, 2, 3), default=3, help='1=Q60, 2=Q75, 3=Q85')
    parser.add_argument('--capture', action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument('--adaptive', action=argparse.BooleanOptionalAction, default=None)
    parser.add_argument('--serial', default='FTB7MA1D')
    parser.add_argument('--library')
    args = parser.parse_args(argv)
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    runner = ThresholdSweep(lambda: FtdiFifo(serial=args.serial, library=d2xx_library(args.library), synchronous=True),
                            args.thresholds, args.seconds, args.output, quality=args.quality, capture=args.capture, adaptive=args.adaptive)
    report = runner.run()
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

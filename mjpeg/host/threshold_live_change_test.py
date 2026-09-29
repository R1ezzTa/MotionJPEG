"""Accept adjustable thresholds while one continuous camera stream is active.

Close the preview first; this test needs exclusive USB_SLAVE access. Thresholds
are dequantized DCT coefficient units. No image is displayed by this script.
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
from camera_viewer import d2xx_library, threshold_command
from ftdi_fifo import FtdiFifo
from threshold_sweep import _decode_jpeg, _quality_table, parse_thresholds


class ThresholdTransitions:
    """Validate old in-flight frames and each newly observed threshold epoch."""
    def __init__(self, thresholds, frames_per_threshold=60, max_transition_frames=90):
        if not thresholds or any(isinstance(x, bool) or not isinstance(x, int) or not 0 <= x <= 255 for x in thresholds):
            raise ValueError('Thresholds must be integers from 0 to 255')
        if frames_per_threshold < 1 or max_transition_frames < 0:
            raise ValueError('Invalid frame count or transition bound')
        self.thresholds = thresholds
        self.frames_per_threshold = frames_per_threshold
        self.max_transition_frames = max_transition_frames
        self.current = None
        self.pending = None
        self.history = []

    def request(self, index, last_frame_id, seconds):
        if self.pending is not None:
            raise ValueError('Threshold command overlaps an unfinished transition')
        if index != len(self.history):
            raise ValueError('Threshold command order')
        self.pending = dict(index=index, threshold=self.thresholds[index],
                            previous_threshold=self.current, command_after_frame_id=last_frame_id,
                            command_seconds=seconds, old_inflight_frames=0,
                            first_frame_id=None, first_frame_keyframe=None, observed_seconds=None,
                            accepted_frames=0)

    def accept(self, frame_id, threshold, keyframe, seconds):
        if self.pending is not None:
            pending = self.pending
            if threshold != pending['threshold']:
                if self.current is None or threshold != self.current:
                    raise ValueError('Unexpected threshold during transition')
                pending['old_inflight_frames'] += 1
                if pending['old_inflight_frames'] > self.max_transition_frames:
                    raise ValueError('Threshold transition exceeded in-flight frame bound')
                return None
            changed = self.current != threshold
            if changed and not keyframe:
                raise ValueError('First frame after threshold change is not a keyframe')
            pending['first_frame_id'] = frame_id
            pending['first_frame_keyframe'] = bool(keyframe)
            pending['observed_seconds'] = seconds
            self.current = threshold
            self.history.append(pending)
            self.pending = None
        elif threshold != self.current:
            raise ValueError('Threshold changed without a command')
        if not self.history:
            raise ValueError('Frame arrived before initial threshold request')
        phase = self.history[-1]
        phase['accepted_frames'] += 1
        phase['last_frame_id'] = frame_id
        return phase['index']

    @property
    def phase_complete(self):
        return bool(self.pending is None and self.history and
                    self.history[-1]['accepted_frames'] >= self.frames_per_threshold)


class LiveThresholdAcceptance:
    def __init__(self, source_factory, thresholds, output, frames_per_threshold=60,
                 quality=3, clock=time.monotonic, transition_timeout=5,
                 max_transition_frames=90, idle_timeout=10, stop_timeout=5,
                 min_fps=29, max_fps=31, capture=True, save_samples=True):
        if quality not in (1, 2, 3) or transition_timeout <= 0 or idle_timeout <= 0 or stop_timeout <= 0:
            raise ValueError('Invalid quality or timeout')
        self.transitions = ThresholdTransitions(thresholds, frames_per_threshold, max_transition_frames)
        self.source_factory = source_factory
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.quality = quality
        self.quantization = _quality_table(quality)
        self.clock = clock
        self.transition_timeout = transition_timeout
        self.idle_timeout = idle_timeout
        self.stop_timeout = stop_timeout
        self.min_fps, self.max_fps = min_fps, max_fps
        self.capture_enabled, self.save_samples = capture, save_samples
        self.source = self.records = self.capture_file = self.pool = None
        self.buffer = bytearray()
        self.frames, self.cameras, self.actions = [], [], []
        self.pending_decodes = deque()
        self.expected_id = self.previous_tick = None
        self.starts = self.ends = 0
        self.streaming = self.start_requested = False
        self.stop_wall = None
        self.sampled = set()
        self.usb_read_bytes = 0

    def command(self, value):
        self.source.write(value)
        self.source.flush()
        self.actions.append(dict(seconds=self.clock() - self.began, command=value.decode('ascii')))

    def check_control(self):
        now = self.clock()
        if now - self.last_data > self.idle_timeout:
            raise TimeoutError('No USB data during live threshold test')
        pending = self.transitions.pending
        if pending is not None and self.streaming and now - self.began - pending['command_seconds'] > self.transition_timeout:
            raise TimeoutError('Threshold command was not observed before the transition timeout')
        if self.stop_wall is not None and now - self.stop_wall > self.stop_timeout:
            raise TimeoutError('No END/stopped snapshot after S')
        if not self.start_requested and now - self.began > self.idle_timeout:
            raise TimeoutError('Camera did not become ready and stopped')
        if self.start_requested and not self.starts and now - self.requested_wall > self.idle_timeout:
            raise TimeoutError('No START after C')

    def exact(self, count):
        self.check_control()
        while len(self.buffer) < count:
            self.check_control()
            data = self.source.read_chunk()
            if data:
                self.last_data = self.clock()
                self.usb_read_bytes += len(data)
                self.buffer.extend(data)
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        if self.capture_file is not None:
            self.capture_file.write(result)
        return result

    def request_threshold(self, index):
        last_id = self.frames[-1]['frame_id'] if self.frames else None
        self.transitions.request(index, last_id, self.clock() - self.began)
        self.command(threshold_command(self.transitions.thresholds[index]))

    def begin(self):
        self.command(str(self.quality).encode('ascii'))
        self.request_threshold(0)
        if self.capture_enabled:
            self.capture_file = (self.output / 'usb_capture.bin').open('wb')
        self.capture_wire_begin = self.records.wire_bytes
        self.requested_wall = self.clock()
        self.start_requested = True
        self.command(b'C')

    def accept_frame(self, frame):
        if frame.status or frame.jpeg is None:
            raise ValueError(f'Frame {frame.frame_id} status={frame.status}')
        if self.expected_id is not None and frame.frame_id != self.expected_id:
            raise ValueError('Frame ID continuity failed')
        if self.previous_tick is not None and frame.timestamp <= self.previous_tick:
            raise ValueError('Frame timestamp continuity failed')
        self.expected_id = (frame.frame_id + 1) & 0xffffffff
        self.previous_tick = frame.timestamp
        if not self.start_requested:
            return  # Drain a retained initial stream after issuing S.
        if not self.streaming:
            raise ValueError('Frame outside the acceptance START/END stream')
        stats = self.records.spatial_stats
        if not stats or stats.get('frame_id') != frame.frame_id or 'threshold' not in stats:
            raise ValueError('Adjustable SPJ2 frame required')
        phase_index = self.transitions.accept(frame.frame_id, stats['threshold'], stats['keyframe'], self.clock() - self.began)
        size = (frame.width, frame.height)
        with Image.open(io.BytesIO(frame.jpeg)) as image:
            if image.format != 'JPEG' or image.size != size or image.quantization != self.quantization:
                raise ValueError('JPEG descriptor/complete requested DQT mismatch')
        self.pending_decodes.append(self.pool.submit(_decode_jpeg, frame.jpeg, size))
        while self.pending_decodes and (self.pending_decodes[0].done() or len(self.pending_decodes) >= 64):
            self.pending_decodes.popleft().result()
        if self.save_samples and stats['threshold'] not in self.sampled:
            target = self.output / f"sample_threshold_{stats['threshold']:03d}.jpg"
            target.write_bytes(frame.jpeg)
            metadata = dict(bytes=len(frame.jpeg), width=frame.width, height=frame.height, format='JPEG', threshold=stats['threshold'])
            target.with_suffix('.metadata.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
            self.sampled.add(stats['threshold'])
        self.frames.append(dict(frame_id=frame.frame_id, timestamp=frame.timestamp,
                                threshold=stats['threshold'], phase_index=phase_index,
                                width=frame.width, height=frame.height, keyframe=stats['keyframe'],
                                transport_bytes=stats['transport_bytes'], jpeg_bytes=len(frame.jpeg),
                                reused=stats['reused'], groups=stats['groups']))
        if self.stop_wall is None and self.transitions.phase_complete:
            index = len(self.transitions.history)
            if index < len(self.transitions.thresholds):
                self.request_threshold(index)
            else:
                self.command(b'S')
                self.stop_wall = self.clock()

    def run(self):
        # Import Pillow's format handlers before USB begins streaming; lazy
        # plugin initialization must not pause the first high-rate frame read.
        Image.init()
        self.began = self.last_data = self.clock()
        error = None
        wire_bytes = 0
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix='live-threshold-jpeg')
        try:
            self.source = self.source_factory()
            self.records = BlockRecords(self.exact)
            self.command(b'l')
            self.command(b'S')
            complete = False
            while not complete:
                kind, value = self.records.next()
                if kind == 'camera':
                    self.cameras.append(value.copy())
                    if not value.get('threshold_capable') or not value.get('board_controls'):
                        raise ValueError('Firmware lacks adjustable threshold controls; no T command sent')
                    if value['overflow_count'] or any(value[name] for name in ('init_error', 'config_error', 'light_error')):
                        raise ValueError(f'Camera FIFO/controller error: {value}')
                    stopped = not value['streaming'] and not value['run_requested']
                    if not self.start_requested and stopped and value['init_done'] and value.get('sampling_ready') and not self.records.in_stream:
                        self.begin()
                    elif self.ends and stopped and not value['light_on']:
                        complete = True
                elif kind == 'start' and self.start_requested:
                    self.starts += 1
                    if self.starts != 1 or self.ends:
                        raise ValueError('Expected exactly one continuous START/END')
                    self.streaming = True
                elif kind == 'frame':
                    self.accept_frame(value)
                elif kind == 'end' and self.start_requested:
                    self.ends += 1
                    self.streaming = False
                    if self.starts != 1 or self.ends != 1 or self.stop_wall is None:
                        raise ValueError('Premature or duplicate END')
                    wire_bytes = self.records.wire_bytes - self.capture_wire_begin
                    if self.capture_file is not None:
                        self.capture_file.close()
                        self.capture_file = None
                    # Receiving has stopped, so decode completion cannot hold
                    # back a running camera while we verify every future.
                    while self.pending_decodes:
                        self.pending_decodes.popleft().result()
                for history in (self.records.rates, self.records.timings, self.records.links, self.records.camera_status):
                    if len(history) > 2:
                        del history[:-2]
            if len(self.transitions.history) != len(self.transitions.thresholds) or not self.transitions.phase_complete:
                raise ValueError('Not all requested thresholds completed')
            delta = [b['timestamp'] - a['timestamp'] for a, b in zip(self.frames, self.frames[1:])]
            # A median can still read 30 fps while every fifth sensor frame is
            # rejected. Check elapsed sensor time and the longest interval.
            fps = 100_000_000 / statistics.mean(delta) if delta else 0
            if not self.min_fps <= fps <= self.max_fps:
                raise ValueError(f'Camera rate {fps:.4f} fps outside {self.min_fps}–{self.max_fps}')
            if max(delta, default=0) > 100_000_000 / self.min_fps:
                raise ValueError('Camera frame interval exceeds the continuous frame-rate limit')
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
            while self.pending_decodes:
                try:
                    self.pending_decodes.popleft().result()
                except Exception as exc:
                    error = error or f'Independent JPEG decode failed: {exc}'
            self.pool.shutdown(wait=True)
        deltas = [b['timestamp'] - a['timestamp'] for a, b in zip(self.frames, self.frames[1:])]
        report = dict(passed=error is None, error=error, thresholds=self.transitions.thresholds,
                      frames_per_threshold=self.transitions.frames_per_threshold,
                      quality=(60, 75, 85)[self.quality - 1],
                      starts=self.starts, ends=self.ends, frames=len(self.frames),
                      median_fps=100_000_000 / statistics.median(deltas) if deltas else 0,
                      mean_fps=100_000_000 / statistics.mean(deltas) if deltas else 0,
                      maximum_frame_interval_ms=max(deltas, default=0) / 100_000,
                      transitions=self.transitions.history, unfinished_transition=self.transitions.pending,
                      wire_bytes=wire_bytes, usb_read_bytes=self.usb_read_bytes,
                      transport_payload_bytes=sum(f['transport_bytes'] for f in self.frames),
                      reconstructed_jpeg_bytes=sum(f['jpeg_bytes'] for f in self.frames),
                      reused_groups=sum(f['reused'] for f in self.frames),
                      camera_fifo_overflows=self.cameras[-1]['overflow_count'] if self.cameras else None,
                      actions=self.actions, capture_enabled=self.capture_enabled,
                      threshold_units='maximum absolute dequantized DCT coefficient difference')
        for name, data in (('summary.json', report), ('frames.json', self.frames), ('camera_status.json', self.cameras)):
            (self.output / name).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
        if error is None:
            (self.output / 'THRESHOLD_LIVE_CHANGE_PASS.txt').write_text('One START/END, live T commands, bounded in-flight transition frames, first-change keyframes, every independent JPEG decode, full DQT, frame sequence, 30 fps and zero camera FIFO overflow passed.\n', encoding='utf-8')
        return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--thresholds', type=parse_thresholds, default=parse_thresholds('0,32,64,0'))
    parser.add_argument('--frames-per-threshold', type=int, default=60)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--quality', type=int, choices=(1, 2, 3), default=3)
    parser.add_argument('--transition-timeout', type=float, default=5)
    parser.add_argument('--max-transition-frames', type=int, default=90)
    parser.add_argument('--capture', action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument('--save-samples', action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument('--serial', default='FTB7MA1D')
    parser.add_argument('--library')
    args = parser.parse_args(argv)
    if args.frames_per_threshold < 2 or args.transition_timeout <= 0 or args.max_transition_frames < 0:
        parser.error('Use at least 2 frames per threshold, a positive timeout and a nonnegative in-flight bound')
    runner = LiveThresholdAcceptance(lambda: FtdiFifo(serial=args.serial, library=d2xx_library(args.library), synchronous=True),
                                     args.thresholds, args.output, args.frames_per_threshold, quality=args.quality,
                                     transition_timeout=args.transition_timeout, max_transition_frames=args.max_transition_frames,
                                     capture=args.capture, save_samples=args.save_samples)
    report = runner.run()
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

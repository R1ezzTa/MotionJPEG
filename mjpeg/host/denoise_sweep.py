"""Compare FPGA spatial denoise strengths using independent JPEG frames.

Close the preview first: the sweep needs exclusive USB_SLAVE access. Each
setting starts a fresh stream after board readback and saves a complete MBLK
capture. Sequential scene captures are not an identical-input comparison.
"""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import io
import json
import math
from pathlib import Path
import statistics
import time

from PIL import Image
from block_records import BlockRecords
from camera_viewer import d2xx_library, denoise_command
from ftdi_fifo import FtdiFifo


def _quality_table(level):
    path = Path(__file__).resolve().parents[1] / 'data/board_test/camera_quant.mem'
    values = [int(line, 16) & 255 for line in path.read_text().splitlines()]
    offset = (level - 1) * 128
    return {0: values[offset:offset + 64], 1: values[offset + 64:offset + 128]}


def _decode_jpeg(data, expected_size):
    with Image.open(io.BytesIO(data)) as image:
        assert image.format == 'JPEG' and image.size == expected_size
        image.load()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strengths', default='0,8,16,32,64,255,0')
    parser.add_argument('--seconds', type=float, default=4)
    parser.add_argument('--quality', type=int, choices=(1, 2, 3), default=3)
    parser.add_argument('--serial', default='FTB7MA1D')
    parser.add_argument('--library')
    parser.add_argument('--require-revision', type=int, choices=(1, 2), default=None,
                        help='Reject firmware of a different denoise revision before START')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        strengths = [int(value) for value in args.strengths.split(',')]
        if not strengths or any(not 0 <= value <= 255 for value in strengths):
            raise ValueError()
    except ValueError:
        parser.error('--strengths must be comma-separated integers from 0 to 255')
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error('--seconds must be finite and positive')
    args.output.mkdir(parents=True, exist_ok=True)
    expected_table = _quality_table(args.quality)
    source = capture_file = records = phase = None
    buffer = bytearray()
    phases, cameras, actions = [], [], []
    pending = deque()
    next_id = previous_tick = None
    began = last_data = waiting_since = time.monotonic()
    probe_before = probe_window = None
    legacy_probe_passed = False
    error = None
    pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix='denoise-jpeg')

    def command(value):
        source.write(value);source.flush()
        actions.append(dict(seconds=time.monotonic() - began, command=value.decode('ascii')))

    def check_control():
        now = time.monotonic()
        if now - last_data > 10:
            raise TimeoutError('No USB data')
        if phase:
            state = phase['state']
            if state == 'running' and now - phase['start_wall'] >= args.seconds:
                command(b'S');phase.update(state='stopping', stop_wall=now)
            elif state == 'stopping' and now - phase['stop_wall'] > 5:
                raise TimeoutError('No END after stop')
            elif state in ('configuring', 'starting') and now - phase['request_wall'] > 10:
                raise TimeoutError(f'No denoise readback/START at {state}')
        elif now - waiting_since > 10:
            raise TimeoutError('Camera did not become ready and stopped')

    def exact(count):
        nonlocal last_data
        check_control()
        while len(buffer) < count:
            check_control()
            data = source.read_chunk()
            if data:
                last_data = time.monotonic();buffer.extend(data)
        value = bytes(buffer[:count]);del buffer[:count]
        if capture_file:
            capture_file.write(value)
        return value

    try:
        Image.init()
        source = FtdiFifo(serial=args.serial, library=d2xx_library(args.library), synchronous=True)
        command(b'l');command(b'S')
        records = BlockRecords(exact)
        while len(phases) < len(strengths):
            kind, value = records.next()
            now = time.monotonic()
            if kind == 'camera':
                cameras.append(dict(value, seconds=now - began))
                assert value.get('denoise_capable'), 'Spatial denoise firmware required'
                assert args.require_revision is None or value['denoise_revision'] == args.require_revision, 'Wrong denoise firmware revision'
                assert not value.get('threshold_capable') and not value.get('adaptive_capable'), 'Interframe firmware still active'
                assert not value['init_error'] and not value['config_error'] and not value['light_error'], 'Camera/control error'
                assert value['overflow_count'] == 0, 'Camera FIFO overflow'
                ready = value['init_done'] and value.get('sampling_ready') and not value['streaming'] and not value['run_requested']
                if phase is None and ready:
                    if not legacy_probe_passed:
                        if probe_before is None:
                            probe_before, probe_window = value['denoise_requested'], value.get('window')
                            command(b'TFF\nA1\nNSCL\n')
                            continue
                        if value.get('window') == probe_window:
                            continue
                        assert value['denoise_requested'] == probe_before and not value['light_on'], 'Removed/malformed command changed controls'
                        legacy_probe_passed = True
                    strength = strengths[len(phases)]
                    directory = args.output / f'{len(phases):02d}_strength_{strength:03d}'
                    directory.mkdir(parents=True, exist_ok=True)
                    phase = dict(state='configuring', strength=strength, directory=str(directory.resolve()),
                                 request_wall=now, frames=[], starts=0, ends=0, wire_begin=records.wire_bytes)
                    capture_file = (directory / 'usb_capture.bin').open('wb')
                    command(str(args.quality).encode('ascii'));command(denoise_command(strength))
                elif phase and phase['state'] == 'configuring' and ready and value['denoise_requested'] == phase['strength']:
                    command(b'C');phase.update(state='starting', request_wall=now)
            elif kind == 'start':
                if phase is None:
                    continue  # Drain a retained RUN session after the initial S.
                assert phase and phase['state'] == 'starting', 'Unexpected START'
                phase.update(state='running', start_wall=now)
                phase['starts'] += 1
            elif kind == 'frame':
                frame = value
                assert frame.status == 0 and frame.jpeg is not None, f'Failed frame {frame.frame_id}'
                assert frame.channel == 0 and not frame.gray and (frame.width, frame.height) == (1920, 1080), 'Wrong descriptor'
                assert records.spatial_stats is None and frame.jpeg.startswith(b'\xff\xd8'), 'Expected independent JPEG'
                assert next_id is None or frame.frame_id == next_id, 'Frame ID gap'
                assert previous_tick is None or frame.timestamp > previous_tick, 'Timestamp order'
                next_id = (frame.frame_id + 1) & 0xffffffff;previous_tick = frame.timestamp
                if phase is None:
                    continue
                assert phase['state'] in ('running', 'stopping'), 'Frame before START'
                with Image.open(io.BytesIO(frame.jpeg)) as image:
                    assert image.format == 'JPEG' and image.size == (1920, 1080), 'Wrong JPEG dimensions'
                    assert image.quantization == expected_table, 'Mixed/incomplete quality table'
                pending.append(pool.submit(_decode_jpeg, frame.jpeg, (1920, 1080)))
                while pending and (pending[0].done() or len(pending) >= 64):
                    pending.popleft().result()
                if not phase['frames']:
                    (Path(phase['directory']) / 'first_frame.jpg').write_bytes(frame.jpeg)
                phase['frames'].append(dict(frame_id=frame.frame_id, timestamp=frame.timestamp,
                                            bytes=frame.length, strength=phase['strength'], status=frame.status))
            elif kind == 'end':
                if phase is None:
                    waiting_since = now;continue
                assert phase['state'] == 'stopping' and phase['frames'], 'Premature/empty END'
                phase['ends'] += 1
                while pending:
                    pending.popleft().result()
                capture_file.close();capture_file = None
                frames = phase['frames']
                deltas = [b['timestamp'] - a['timestamp'] for a, b in zip(frames, frames[1:])]
                assert deltas and max(deltas) < 3_400_000, 'Frame interval exceeded 34 ms'
                fps = 100_000_000 / statistics.mean(deltas)
                payload = sum(frame['bytes'] for frame in frames)
                summary = dict(strength=phase['strength'], frames=len(frames), decoded_frames=len(frames),
                               starts=phase['starts'], ends=phase['ends'], mean_fps=fps,
                               max_frame_interval_ms=max(deltas) / 100_000,
                               mean_jpeg_bytes=payload / len(frames), jpeg_payload_bytes=payload,
                               jpeg_mb_per_second=payload / len(frames) * fps / 1_000_000,
                               wire_bytes=records.wire_bytes - phase['wire_begin'],
                               camera_fifo_overflows=0, independent_jpeg=True, directory=phase['directory'])
                directory = Path(phase['directory'])
                (directory / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
                (directory / 'frames.json').write_text(json.dumps(frames, indent=2) + '\n', encoding='utf-8')
                phases.append(summary)
                print(f"Denoise {summary['strength']:3d}: {len(frames)} frames, {fps:.4f} fps, JPEG {summary['jpeg_mb_per_second']:.3f} MB/s", flush=True)
                phase = None;waiting_since = now
            for history in (records.rates, records.timings, records.links, records.camera_status):
                if len(history) > 2:
                    del history[:-2]
    except Exception as exc:
        error = f'{type(exc).__name__}: {exc}'
    finally:
        pool.shutdown(wait=True)
        if capture_file:
            capture_file.close()
        if source:
            try:
                command(b'l');command(b'S')
            finally:
                source.close()
    report = dict(passed=error is None, error=error, strengths=strengths, seconds_per_strength=args.seconds,
                  quality=(60, 75, 85)[args.quality - 1], required_revision=args.require_revision,
                  observed_revisions=sorted({camera['denoise_revision'] for camera in cameras}), phases=phases,
                  independently_decoded_frames=sum(phase['frames'] for phase in phases), actions=actions,
                  removed_and_malformed_commands_ignored=legacy_probe_passed,
                  comparison_note='Same physical scene captured sequentially, not identical source pixels. JPEG image payload excludes MBLK/USB overhead.',
                  physical_motion_quality_verified=False)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    (args.output / 'camera_status.json').write_text(json.dumps(cameras, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(passed=report['passed'], error=error, frames=report['independently_decoded_frames']), indent=2), flush=True)
    return 1 if error else 0


if __name__ == '__main__':
    raise SystemExit(main())

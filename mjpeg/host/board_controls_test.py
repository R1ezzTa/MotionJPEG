"""Live acceptance of the FPGA controller via its USB compatibility commands.

This verifies hardware state/table/light logic, not physical button presses.
Requires the new board-controls bitstream. Saves metadata and one JPEG per Q.
"""
import argparse
import io
import json
import statistics
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from PIL import Image
from block_records import BlockRecords
from camera_viewer import d2xx_library, threshold_command, adaptive_command
from ftdi_fifo import FtdiFifo


def quantizers():
    path = Path(__file__).resolve().parents[1] / 'data/board_test/camera_quant.mem'
    values = [int(line, 16) & 255 for line in path.read_text().splitlines()]
    return {q: {0: values[i*128:i*128+64], 1: values[i*128+64:(i+1)*128]}
            for i, q in enumerate((60, 75, 85))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', default='FTB7MA1D')
    parser.add_argument('--library')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expect-spatial', action='store_true')
    parser.add_argument('--skip-threshold', type=int, default=None)
    parser.add_argument('--adaptive', action=argparse.BooleanOptionalAction, default=None)
    args = parser.parse_args()
    if args.skip_threshold is not None and not 0 <= args.skip_threshold <= 255:
        parser.error('--skip-threshold must be from 0 to 255')
    args.output.mkdir(parents=True, exist_ok=True)
    tables = quantizers()
    source = None
    buffer = bytearray()
    frames, cameras, actions = [], [], []
    starts = ends = 0
    phase = 'initial'
    phase_start = began = time.monotonic()
    next_action = 0
    expected_id = previous_tick = None
    light_seen = light_off_seen = False
    error = None
    decode_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix='jpeg-acceptance')
    pending_decodes = deque()
    def decode_jpeg(data):
        with Image.open(io.BytesIO(data)) as image:
            image.load()
    schedule = [(4, b'1'), (8, b'2'), (12, b'3'), (16, b'S')]

    def command(value):
        source.write(value)
        source.flush()
        actions.append(dict(seconds=time.monotonic()-began, command=value.decode()))

    def exact(n):
        nonlocal next_action
        while len(buffer) < n:
            now = time.monotonic()
            if now-began > 60:
                raise TimeoutError(f'Board control acceptance timeout, phase={phase}')
            if phase == 'qualities' and next_action < len(schedule):
                delay, value = schedule[next_action]
                if now-phase_start >= delay:
                    command(value)
                    next_action += 1
            if phase == 'restart':
                if next_action == 0 and now-phase_start >= 2:
                    command(b'L');next_action = 1
                elif next_action == 1 and now-phase_start >= 7:
                    command(b'S');next_action = 2
            buffer.extend(source.read_chunk())
        value = bytes(buffer[:n])
        del buffer[:n]
        return value

    try:
        Image.init()
        source = FtdiFifo(serial=args.serial, library=d2xx_library(args.library), synchronous=True)
        records = BlockRecords(exact)
        while True:
            kind, value = records.next()
            now = time.monotonic()
            if kind == 'start':
                starts += 1
            elif kind == 'end':
                ends += 1
                phase = 'stopped' if ends == 1 else 'final'
                phase_start = now
            elif kind == 'camera':
                value = dict(value, seconds=now-began)
                cameras.append(value)
                assert value.get('board_controls'), 'Wrong firmware: board controls missing'
                assert not value['init_error'] and not value['config_error'] and not value['light_error'], f'Camera/control errors: {value}'
                assert value['overflow_count'] == 0, 'Camera FIFO overflow'
                if phase == 'initial' and value['init_done'] and value.get('sampling_ready'):
                    assert not value['streaming'] and not value['run_requested'], 'Startup was not stopped'
                    assert value['quality_requested'] == 85, 'Wrong default quality'
                    if args.skip_threshold is not None:
                        assert value.get('threshold_capable'), 'Adjustable threshold firmware required'
                        command(threshold_command(args.skip_threshold))
                    if args.adaptive is not None:
                        assert value.get('adaptive_capable'), 'Board adaptive mode firmware required'
                        command(adaptive_command(args.adaptive))
                    command(b'C');phase = 'qualities';phase_start = now
                elif phase == 'stopped' and not value['streaming'] and not value['run_requested'] and now-phase_start >= 1:
                    command(b'C');phase = 'restart';phase_start = now;next_action = 0
                if phase in ('restart', 'final'):
                    light_seen |= value['light_on']
                    if phase == 'restart' and next_action == 1 and light_seen and not value['light_on'] and not value['light_requested']:
                        light_off_seen = True
                if phase == 'final' and not value['streaming'] and not value['run_requested'] and not value['light_on']:
                    break
            elif kind == 'frame':
                frame = value
                assert frame.status == 0 and (frame.width, frame.height) == (1920, 1080), f'Frame {frame.frame_id}: status={frame.status}, dimensions={frame.width}x{frame.height}'
                assert expected_id is None or frame.frame_id == expected_id, 'Frame ID gap'
                assert previous_tick is None or frame.timestamp > previous_tick
                expected_id = (frame.frame_id+1) & 0xffffffff
                previous_tick = frame.timestamp
                with Image.open(io.BytesIO(frame.jpeg)) as image:
                    matching = [q for q, table in tables.items() if image.quantization == table]
                    assert len(matching) == 1, 'Mixed/incomplete quantizer table in JPEG'
                    quality = matching[0]
                    assert image.size == (1920, 1080)
                pending_decodes.append(decode_pool.submit(decode_jpeg, frame.jpeg))
                while pending_decodes and (pending_decodes[0].done() or len(pending_decodes)>=64):
                    pending_decodes.popleft().result()
                if not any(item['quality'] == quality for item in frames):
                    (args.output / f'sample_q{quality}.jpg').write_bytes(frame.jpeg)
                frames.append(dict(frame_id=frame.frame_id, timestamp=frame.timestamp,
                                   bytes=frame.length, quality=quality, session=starts,
                                   seconds=now-began, phase=phase, spatial=records.spatial_stats))
                if args.expect_spatial:
                    assert records.spatial_stats is not None, 'Spatial firmware required'
                if args.skip_threshold is not None:
                    assert records.spatial_stats is not None and records.spatial_stats.get('threshold') == args.skip_threshold, 'Wrong active frame threshold'
                if args.adaptive is not None:
                    assert records.spatial_stats is not None and records.spatial_stats.get('adaptive', False) == args.adaptive, 'Wrong adaptive mode'
            for history in (records.rates, records.timings, records.links, records.camera_status):
                if len(history) > 2:
                    del history[:-2]
        for pending in pending_decodes:
            pending.result()
        pending_decodes.clear()
        assert starts == ends == 2 and light_seen and light_off_seen
        assert {frame['quality'] for frame in frames} == {60, 75, 85}
        quality_trace = []
        for frame in frames:
            if frame['session'] == 1 and (not quality_trace or quality_trace[-1] != frame['quality']):
                quality_trace.append(frame['quality'])
        assert quality_trace == [85, 60, 75, 85], f'Wrong quality transition order: {quality_trace}'
        assert cameras[-1]['overflow_count'] == 0 and not records.in_stream
    except Exception as exc:
        error = f'{type(exc).__name__}: {exc}'
    finally:
        decode_pool.shutdown(wait=True)
        if source is not None:
            try:
                source.write(b'l');source.write(b'S');source.flush()
            finally:
                source.close()
    groups = {}
    # Use only adjacent frames of the same Q/session to exclude switch and idle gaps.
    for quality in (60, 75, 85):
        selected = [frame for frame in frames if frame['quality'] == quality]
        delta = [b['timestamp']-a['timestamp'] for a, b in zip(frames, frames[1:])
                 if a['quality'] == b['quality'] == quality and a['session'] == b['session']]
        groups[quality] = dict(frames=len(selected),
                               mean_jpeg_bytes=statistics.mean(f['bytes'] for f in selected) if selected else 0,
                               median_fps=100_000_000/statistics.median(delta) if delta else 0)
    report = dict(passed=error is None, error=error, decoded_frames=len(frames),
                  adaptive=args.adaptive,
                  skip_threshold=args.skip_threshold,
                  starts=starts, ends=ends, qualities=groups, actions=actions,
                  camera_fifo_overflows=cameras[-1]['overflow_count'] if cameras else None,
                  light_readback_on=light_seen, automatic_off_seen_before_stop=light_off_seen,
                  physical_buttons_tested=False, physical_light_observed=False)
    if args.expect_spatial:
        spatial=[f['spatial'] for f in frames]
        report['spatial']=dict(reconstructed_jpeg_bytes=sum(f['jpeg_bytes'] for f in spatial),
                               transport_payload_bytes=sum(f['transport_bytes'] for f in spatial),
                               reused_groups=sum(f['reused'] for f in spatial),
                               total_groups=sum(f['groups'] for f in spatial),
                               keyframes=sum(f['keyframe'] for f in spatial))
    for name, value in [('summary.json', report), ('frames.json', frames), ('camera_status.json', cameras)]:
        (args.output / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    if error is None:
        (args.output / 'BOARD_CONTROLS_HARDWARE_PASS.txt').write_text('Controller state, three complete DQT sets, independent JPEG decode, two START/END sessions and autonomous light-off readback passed. Physical keys/LED appearance require user observation.\n')
    return 1 if error else 0


if __name__ == '__main__':
    raise SystemExit(main())

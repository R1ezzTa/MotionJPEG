"""Sweep dead-zone thresholds over the same historical MJPEG input.

Restart transcoding preserves quantized coefficients. Each COPY retains the
last emitted same-position group, not the preceding raw frame. The default
model mirrors the FPGA's 192 x 256-byte cache, selecting one group in 21.
RGB error is measured numerically; this tool never displays source images.
"""
import argparse
import io
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from analyze_spatial_capture import add_restart
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from block_records import BlockRecords
from spatial_coefficients import decode_restart_group, parse_header
from spatial_jpeg import NONE, THRESHOLD_MAGIC, SpatialDecoder, split_jpeg

CACHE_SLOTS = 192
CACHE_SLOT_BYTES = 256
CACHE_STRIDE = 21


def candidate(index, group, full_cache=False):
    return full_cache or (index % CACHE_STRIDE == 0 and
                          index // CACHE_STRIDE < CACHE_SLOTS and
                          len(group) <= CACHE_SLOT_BYTES)


def coefficient_vector(group, config):
    decoded = decode_restart_group(group, config)
    # Compact signed vectors can be shared among all threshold models, avoiding
    # seven separate Huffman decodes and millions of Python integer references.
    return np.fromiter((c * q for block in decoded.blocks for c, q in
                        zip(block.coefficients, block.quantization)), dtype=np.int32)


class ThresholdCacheEncoder:
    def __init__(self, threshold, full_cache=False, refresh_period=30):
        if isinstance(threshold, bool) or not isinstance(threshold, int) or not 0 <= threshold <= 255:
            raise ValueError('Threshold must be an integer from 0 to 255')
        if refresh_period <= 0:
            raise ValueError('Refresh period must be positive')
        self.threshold = threshold
        self.full_cache = full_cache
        self.refresh_period = refresh_period
        self.frame_id = self.header = None
        self.frames_since_refresh = 0
        self.cache = {}
        self.last_stats = None

    def encode(self, parsed, vectors, frame_id, force_refresh=False):
        key = (force_refresh or self.frame_id is None or frame_id != self.frame_id + 1 or
               parsed.header != self.header or self.frames_since_refresh >= self.refresh_period)
        if key:
            self.cache.clear()
            self.frames_since_refresh = 0
        out = bytearray(struct.pack('<4sBIB', THRESHOLD_MAGIC, int(key),
                                    NONE if key else self.frame_id, self.threshold))
        out += struct.pack('<BH', 0, len(parsed.header)) + parsed.header
        reused = covered = possible_saved = 0
        for index, group in enumerate(parsed.groups):
            eligible = candidate(index, group, self.full_cache)
            if eligible:
                covered += 1
                possible_saved += len(group) + 2
            previous = self.cache.get(index)
            same = (not key and eligible and previous is not None and
                    np.all(np.abs(vectors[index] - previous[1]) <= self.threshold))
            if same:
                out += struct.pack('<BH', 2, index)
                reused += 1
            else:
                out += struct.pack('<BHH', 1, index, len(group)) + group
                if eligible:
                    self.cache[index] = (group, vectors[index])
                else:
                    self.cache.pop(index, None)
        self.header = parsed.header
        self.frame_id = frame_id
        self.frames_since_refresh += 1
        all_data_bytes = 13 + len(parsed.header) + sum(5 + len(group) for group in parsed.groups)
        self.last_stats = dict(eligible_groups=covered, coverage_fraction=covered / len(parsed.groups),
                               all_data_bytes=all_data_bytes,
                               optimistic_payload_floor_bytes=(all_data_bytes if key else
                                                               all_data_bytes - possible_saved),
                               maximum_record_savings_bytes=0 if key else possible_saved)
        return bytes(out)


def rgb(jpeg):
    with Image.open(io.BytesIO(jpeg)) as image:
        return np.asarray(image.convert('RGB'))


def difference(actual, reference):
    delta = actual.astype(np.int16) - reference.astype(np.int16)
    return dict(abs_sum=int(np.abs(delta).sum()),
                squared_sum=float(np.square(delta.astype(np.float64)).sum()),
                samples=int(delta.size), max_error=int(np.abs(delta).max()) if delta.size else 0)


def error_summary(abs_sum, squared_sum, samples, max_error):
    if not samples:
        return dict(rgb_mae=None, rgb_mse=None, rgb_psnr_db=None, rgb_exact=True, rgb_max_error=0)
    mse = squared_sum / samples
    return dict(rgb_mae=abs_sum / samples, rgb_mse=mse,
                rgb_psnr_db=10 * math.log10(255 * 255 / mse) if mse else None,
                rgb_exact=mse == 0, rgb_max_error=max_error)


def cache_region_mask(parsed, full_cache=False):
    """Coordinates eligible for the modeled cache on this current frame."""
    mask = np.zeros((parsed.height, parsed.width), dtype=bool)
    for index, group in enumerate(parsed.groups):
        if candidate(index, group, full_cache):
            x, y, width, height = parsed.rectangle(index)
            mask[y:y + height, x:x + width] = True
    return mask


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--frames', type=int, default=12)
    parser.add_argument('--skip', type=int, default=100)
    parser.add_argument('--thresholds', default='0,8,16,32,64,128,255',
                        help='Comma-separated coefficient thresholds from 0 through 255')
    parser.add_argument('--refresh-period', type=int, default=30)
    parser.add_argument('--full-cache', action='store_true',
                        help='Also model unlimited host caching; not the current FPGA resource budget')
    args = parser.parse_args(argv)
    try:
        args.thresholds = tuple(dict.fromkeys(int(value) for value in args.thresholds.split(',')))
    except ValueError:
        parser.error('--thresholds must be comma-separated integers')
    if not args.thresholds or any(not 0 <= value <= 255 for value in args.thresholds):
        parser.error('Thresholds must be from 0 through 255')
    if args.frames <= 0 or args.skip < 0 or args.refresh_period <= 0:
        parser.error('Frames and refresh period must be positive; skip must be nonnegative')
    return args


def main(argv=None):
    args = parse_args(argv)
    args.output.mkdir(parents=True, exist_ok=True)
    modes = ['board_cache'] + (['full_cache'] if args.full_cache else [])
    models = {(mode, threshold): ThresholdCacheEncoder(threshold, mode == 'full_cache', args.refresh_period)
              for mode in modes for threshold in args.thresholds}
    decoders = {key: SpatialDecoder() for key in models}
    previous_outputs = {}
    previous_current = None
    result = []
    count = 0
    force_refresh = True
    last_source_id = None
    with args.capture.open('rb') as source:
        records = BlockRecords(source.read)
        while len(result) < args.frames:
            try:
                kind, frame = records.next()
            except struct.error as exc:
                raise ValueError(f'Capture ended before {args.frames} selected frames') from exc
            if kind == 'start':
                force_refresh = True
                last_source_id = None
            if kind != 'frame':
                continue
            if frame.status:
                force_refresh = True
                continue
            count += 1
            if count <= args.skip:
                continue
            restarted = add_restart(frame.jpeg)
            current_rgb = rgb(restarted)
            if not np.array_equal(current_rgb, rgb(frame.jpeg)):
                raise AssertionError('Restart transcoding changed decoded RGB pixels')
            parsed = split_jpeg(restarted)
            config = parse_header(parsed.header)
            # Decode each selected region once for the entire threshold sweep.
            vectors = {index: coefficient_vector(group, config)
                       for index, group in enumerate(parsed.groups)
                       if candidate(index, group, args.full_cache)}
            region_masks = {mode: cache_region_mask(parsed, mode == 'full_cache') for mode in modes}
            item = dict(source_frame_id=frame.frame_id, source_timestamp=frame.timestamp,
                        original_jpeg_bytes=len(frame.jpeg), restart_jpeg_bytes=len(restarted),
                        dimensions=[frame.width, frame.height], groups=len(parsed.groups), modes={})
            if previous_current is not None:
                temporal = difference(current_rgb, previous_current)
                item['input_temporal_rgb_mae'] = temporal['abs_sum'] / temporal['samples']
            for (mode, threshold), encoder in models.items():
                packet = encoder.encode(parsed, vectors, len(result), force_refresh or
                                        (last_source_id is not None and frame.frame_id != last_source_id + 1))
                restored = decoders[mode, threshold].decode(packet, len(result))
                output_rgb = current_rgb if restored == restarted else rgb(restored)
                error = difference(output_rgb, current_rgb)
                stats = dict(decoders[mode, threshold].last_stats, **encoder.last_stats,
                             **error_summary(**error), rgb_abs_sum=error['abs_sum'],
                             rgb_squared_sum=error['squared_sum'], rgb_samples=error['samples'])
                mask = region_masks[mode]
                region_error = difference(output_rgb[mask], current_rgb[mask])
                stats.update({'cache_region_' + name: value for name, value in
                              error_summary(**region_error).items()})
                stats.update(cache_region_abs_sum=region_error['abs_sum'],
                             cache_region_squared_sum=region_error['squared_sum'],
                             cache_region_samples=region_error['samples'],
                             cache_region_pixel_fraction=float(mask.mean()))
                if threshold == 0 and restored != restarted:
                    raise AssertionError('Zero threshold changed restart JPEG bytes')
                if (mode, threshold) in previous_outputs:
                    temporal = difference(output_rgb, previous_outputs[mode, threshold])
                    stats['output_temporal_rgb_mae'] = temporal['abs_sum'] / temporal['samples']
                previous_outputs[mode, threshold] = output_rgb
                item['modes'].setdefault(mode, {})[str(threshold)] = stats
            previous_current = current_rgb
            last_source_id = frame.frame_id
            force_refresh = False
            result.append(item)
            reused = ', '.join(f'{threshold}:{item["modes"]["board_cache"][str(threshold)]["reused"]}'
                               for threshold in args.thresholds)
            print(f'Frame {frame.frame_id}: board groups {len(parsed.groups)}, reused threshold:count {reused}', flush=True)
    original = sum(item['original_jpeg_bytes'] for item in result)
    summary = dict(passed=True, source=str(args.capture.resolve()), selected_frames=len(result),
                   skipped_good_frames=args.skip, thresholds=args.thresholds,
                   refresh_period=args.refresh_period, original_jpeg_bytes=original,
                   restart_jpeg_bytes=sum(item['restart_jpeg_bytes'] for item in result),
                   cache=dict(slots=CACHE_SLOTS, slot_bytes=CACHE_SLOT_BYTES, stride=CACHE_STRIDE,
                              nominal_bytes=CACHE_SLOTS * CACHE_SLOT_BYTES,
                              nominal_1080p_group_coverage=CACHE_SLOTS / 4050),
                   metric_notes=[
                       'Threshold is max absolute dequantized DCT coefficient difference, not RGB brightness.',
                       'COPY retains the last emitted region; accumulated drift is compared to receiver content.',
                       'PSNR null with rgb_exact true means infinite PSNR.',
                       'Temporal MAE includes real motion and lighting; lower values alone do not prove better quality.',
                       'rgb_* metrics cover the full image; cache_region_rgb_* cover only currently cache-eligible same-coordinate regions.',
                       'Byte totals compare encoded payload against the same original MJPEG input, excluding MBLK framing.',
                       'Optimistic payload floor assumes every eligible region can be copied on non-key frames.'],
                   modes={}, frames=result)
    for mode in modes:
        summary['modes'][mode] = {}
        for threshold in args.thresholds:
            selected = [item['modes'][mode][str(threshold)] for item in result]
            size = sum(stats['transport_bytes'] for stats in selected)
            floor = sum(stats['optimistic_payload_floor_bytes'] for stats in selected)
            stats = dict(payload_bytes=size, reduction_vs_original=1 - size / original,
                         reused_groups=sum(value['reused'] for value in selected),
                         total_groups=sum(value['groups'] for value in selected),
                         eligible_groups=sum(value['eligible_groups'] for value in selected),
                         optimistic_payload_floor_bytes=floor,
                         optimistic_reduction_vs_original=1 - floor / original,
                         **error_summary(sum(value['rgb_abs_sum'] for value in selected),
                                         sum(value['rgb_squared_sum'] for value in selected),
                                         sum(value['rgb_samples'] for value in selected),
                                         max(value['rgb_max_error'] for value in selected)))
            stats.update({'cache_region_' + name: value for name, value in
                          error_summary(sum(value['cache_region_abs_sum'] for value in selected),
                                        sum(value['cache_region_squared_sum'] for value in selected),
                                        sum(value['cache_region_samples'] for value in selected),
                                        max(value['cache_region_rgb_max_error'] for value in selected)).items()})
            stats['cache_region_pixel_fraction'] = (sum(value['cache_region_samples'] for value in selected) /
                                                  sum(value['rgb_samples'] for value in selected))
            for field, output in [('output_temporal_rgb_mae', 'mean_output_temporal_rgb_mae')]:
                values = [value[field] for value in selected if field in value]
                if values:
                    stats[output] = sum(values) / len(values)
            summary['modes'][mode][str(threshold)] = stats
    values = [item['input_temporal_rgb_mae'] for item in result if 'input_temporal_rgb_mae' in item]
    if values:
        summary['mean_input_temporal_rgb_mae'] = sum(values) / len(values)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2, allow_nan=False), encoding='utf-8')
    print(json.dumps({key: value for key, value in summary.items() if key != 'frames'}, indent=2, allow_nan=False))
    return summary


if __name__ == '__main__':
    main()

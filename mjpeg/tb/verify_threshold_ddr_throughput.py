"""Independent full-position reference checks for the DDR threshold cache."""
import argparse
import io
import json
import struct
import sys
from pathlib import Path
from PIL import Image
import numpy as np
from spatial_reference import encode_restart
from jpeg_model import tables
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_jpeg import SpatialDecoder, SpatialEncoder, split_jpeg

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--abort-only', action='store_true')
parser.add_argument('--dense-only', action='store_true')
parser.add_argument('--full-only', action='store_true')
parser.add_argument('--early-only', action='store_true')
args = parser.parse_args()

if args.early_only:
    decoder = SpatialDecoder()
    trace = json.loads((args.directory / 'early_expected.json').read_text())
    for row in trace:
        frame_id = row['frame_id']
        packet = (args.directory / f'early_{frame_id}.spj').read_bytes()
        assert packet == (args.directory / f'expected_early_{frame_id}.spj').read_bytes()
        decoder.decode(packet, frame_id)
        assert decoder.last_stats['reused'] == len(row['reused'])
    print('DDR_EARLY_REFERENCE_PASS: early/last coefficient DATA, malformed suffix/current/reference DATA, next-group clean COPY and retained-reference decisions')
    raise SystemExit(0)

if args.full_only:
    decoder = SpatialDecoder()
    trace = json.loads((args.directory / 'full_expected.json').read_text())
    for row in trace:
        frame_id = row['frame_id']
        packet = (args.directory / f'full_{frame_id}.spj').read_bytes()
        assert packet == (args.directory / f'expected_full_{frame_id}.spj').read_bytes()
        decoder.decode(packet, frame_id)
        assert decoder.last_stats['groups'] == 4050 and decoder.last_stats['reused'] == row['reused']
    print('DDR_FULL_REFERENCE_PASS: all4050 positions; final region4049 updates after accumulated drift, never adjacent-source comparison')
    raise SystemExit(0)

if args.dense_only:
    decoder = SpatialDecoder()
    trace = json.loads((args.directory / 'dense_expected.json').read_text())
    for row in trace:
        frame_id = row['frame_id']
        packet = (args.directory / f'dense_{frame_id}.spj').read_bytes()
        assert packet == (args.directory / f'expected_dense_{frame_id}.spj').read_bytes()
        decoder.decode(packet, frame_id)
        assert decoder.last_stats['reused'] == len(row['reused'])
    print('DDR_DENSE_REFERENCE_PASS: four dense1024-coefficient packets exact to retained-reference decisions')
    raise SystemExit(0)

if args.abort_only:
    memory = bytes(int(line, 16) for line in (args.directory / 'threshold_input.mem').read_text().splitlines())
    length = int((args.directory / 'threshold_lengths.mem').read_text().splitlines()[1], 16)
    original = memory[1024:1024 + length]
    for frame_id in (0, 2, 4, 6, 7, 8, 9, 11):
        expected = SpatialEncoder().encode(original, frame_id, force_refresh=True)
        expected = b'SPJ2' + expected[4:9] + bytes((32,)) + expected[9:]
        actual = (args.directory / f'ddr_abort_{frame_id}.spj').read_bytes()
        assert actual == expected, f'Post-abort frame {frame_id} did not force a complete exact refresh'
        assert SpatialDecoder().decode(actual, frame_id) == original
    print('DDR_ABORT_REFERENCE_PASS: eight full refreshes byte-exact after aborted read/write/command, concurrent coefficient decoders, global reset and late invalidate')
    raise SystemExit(0)

decoder = SpatialDecoder()
y, x = np.indices((1080, 1920)); cy, cx = np.indices((1080, 960))
expected_jpeg = encode_restart(((3*x+2*y)&255).astype(np.uint8),
                               ((2*cx+cy+80)&255).astype(np.uint8),
                               ((cx+3*cy+160)&255).astype(np.uint8), False, tables(85))
rows = []
for frame_id in range(2):
    original = (args.directory / f'ddr_fhd_{frame_id}.jpg').read_bytes()
    assert original == expected_jpeg, f'FHD frame {frame_id} differs from independent DCT/quantization/Huffman model'
    packet = (args.directory / f'ddr_fhd_{frame_id}.spj').read_bytes()
    restored = decoder.decode(packet, frame_id)
    assert restored == original, f'FHD frame {frame_id} reference changed unexpectedly'
    assert decoder.last_stats['groups'] == 4050
    assert decoder.last_stats['threshold'] == 128
    assert decoder.last_stats['keyframe'] == (frame_id == 0)
    assert decoder.last_stats['reused'] == (0 if frame_id == 0 else 4050)
    with Image.open(io.BytesIO(restored)) as image:
        image.load()
        assert image.size == (1920, 1080)
    rows.append(dict(frame_id=frame_id, **decoder.last_stats))
assert (args.directory / 'ddr_fhd_0.jpg').read_bytes() == (args.directory / 'ddr_fhd_1.jpg').read_bytes()
timings = json.loads((args.directory / 'ddr_throughput.json').read_text())
for row, timing in zip(rows, timings):
    row['ideal_fps'] = 100_000_000 / timing['total_ticks']
report = dict(passed=True, sustains_1080p30=all(row['ideal_fps'] >= 30 for row in rows),
              all_positions=4050, frames=rows,
              note='Ideal native-memory model. Frame1 includes parallel reference/current entropy decoding for every region; this is simulation, not live-camera throughput.')
(args.directory / 'ddr_fhd_reference.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

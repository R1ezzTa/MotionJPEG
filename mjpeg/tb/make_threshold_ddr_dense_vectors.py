"""Dense 1024-coefficient groups beyond the old 256-byte cache limit."""
import argparse
import json
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_coefficients import decode_restart_group, parse_header, within_deadzone
from spatial_jpeg import SpatialDecoder
from spatial_reference import BitWriter, HUFF, header, segment, symbols

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
args = parser.parse_args()
quant = [int(line, 16) & 255 for line in (Path(__file__).resolve().parents[1] / 'data/board_test/camera_quant.mem').read_text().splitlines()][256:384]
base = header(128, 8, False, quant)
sos = base.rfind(b'\xff\xda')
base = base[:sos] + segment(0xdd, [0, 4]) + base[sos:]
config = parse_header(base)
memory = []
lengths = []
trace = []
reference = None
decoder = SpatialDecoder()
for frame_id in range(4):
    groups = []
    for region in range(2):
        writer = BitWriter()
        previous = [0, 0, 0]
        for block in range(16):
            component = (0, 0, 1, 2)[block % 4]
            coefficients = [100 + (frame_id != 0)] + [1 if frame_id == 0 else 2] * 63
            if frame_id == 2 and region == 0 and block == 0:
                coefficients[63] = 100
            table = 0 if component == 0 else 2
            for dc, sym, amp, count in symbols(coefficients, previous[component]):
                code, bits = HUFF[table + (0 if dc else 1)][sym]
                writer.put(code, bits)
                writer.put(amp, count)
            previous[component] = coefficients[0]
        group = writer.finish() + (b'\xff\xd0' if region == 0 else b'\xff\xd9')
        assert 256 < len(group) <= 8192
        decoded = decode_restart_group(group, config)
        assert sum(sum(value != 0 for value in block.coefficients) for block in decoded.blocks) == 1024
        groups.append(group)
    jpeg = base + b''.join(groups)
    lengths.append(len(jpeg))
    memory.extend(jpeg + bytes(4096 - len(jpeg)))
    key = reference is None
    packet = bytearray(struct.pack('<4sBIB', b'SPJ2', key, 0xffffffff if key else frame_id - 1, 255))
    packet += struct.pack('<BH', 0, len(base)) + base
    retained = []
    reused = []
    for i, group in enumerate(groups):
        copy = not key and within_deadzone(decode_restart_group(group, config),
                                          decode_restart_group(reference[i], config), 255)
        if copy:
            packet += struct.pack('<BH', 2, i)
            retained.append(reference[i]);reused.append(i)
        else:
            packet += struct.pack('<BHH', 1, i, len(group)) + group
            retained.append(group)
    reference = retained
    assert decoder.decode(packet, frame_id) == base + b''.join(reference)
    (args.output / f'expected_dense_{frame_id}.spj').write_bytes(packet)
    trace.append(dict(frame_id=frame_id, threshold=255, keyframe=key, reused=reused, group_bytes=list(map(len, groups))))
assert [row['reused'] for row in trace] == [[], [0, 1], [1], [1]]
(args.output / 'dense_input.mem').write_text(''.join(f'{value:02x}\n' for value in memory))
for name, values in (('lengths', lengths), ('values', [255] * 4)):
    (args.output / f'dense_{name}.mem').write_text(''.join(f'{value:08x}\n' for value in values))
(args.output / 'dense_expected.json').write_text(json.dumps(trace, indent=2) + '\n')
print('DDR_DENSE_VECTORS_PASS: four >256-byte regions, each1024 nonzero coefficients')

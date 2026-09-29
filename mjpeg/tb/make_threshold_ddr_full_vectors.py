"""All 4050 positions, with cumulative drift in the final spatial region."""
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
base = header(1920, 1080, False, quant)
sos = base.rfind(b'\xff\xda')
base = base[:sos] + segment(0xdd, [0, 4]) + base[sos:]
config = parse_header(base)
threshold = min(255, 2 * quant[0])

def entropy(delta):
    writer = BitWriter()
    previous = [0, 0, 0]
    for block in range(16):
        component = (0, 0, 1, 2)[block % 4]
        coefficients = [0] * 64
        coefficients[0] = (100 if component == 0 else 20) + (delta if block == 0 else 0)
        coefficients[3] = 1 if block == 2 else 0
        table = 0 if component == 0 else 2
        for dc, sym, amplitude, count in symbols(coefficients, previous[component]):
            code, length = HUFF[table + (0 if dc else 1)][sym]
            writer.put(code, length);writer.put(amplitude, count)
        previous[component] = coefficients[0]
    return writer.finish()

common = entropy(0)
reference = None
memory = []
lengths = []
trace = []
decoder = SpatialDecoder()
for frame_id in range(4):
    groups = [common + bytes((255, 0xd0 + (i & 7))) for i in range(4049)]
    groups.append(entropy(frame_id) + b'\xff\xd9')
    jpeg = base + b''.join(groups)
    lengths.append(len(jpeg))
    memory.extend(jpeg + bytes(131072 - len(jpeg)))
    key = reference is None
    packet = bytearray(struct.pack('<4sBIB', b'SPJ2', key, 0xffffffff if key else frame_id - 1, threshold))
    packet += struct.pack('<BH', 0, len(base)) + base
    retained = []
    reused = 0
    for i, group in enumerate(groups):
        copy = not key and (group == reference[i] or within_deadzone(
            decode_restart_group(group, config), decode_restart_group(reference[i], config), threshold))
        if copy:
            packet += struct.pack('<BH', 2, i);retained.append(reference[i]);reused += 1
        else:
            packet += struct.pack('<BHH', 1, i, len(group)) + group;retained.append(group)
    reference = retained
    assert decoder.decode(packet, frame_id) == base + b''.join(reference)
    (args.output / f'expected_full_{frame_id}.spj').write_bytes(packet)
    trace.append(dict(frame_id=frame_id, threshold=threshold, keyframe=key, reused=reused,
                      tail_reference_dc=decode_restart_group(reference[-1], config).blocks[0].coefficients[0]))
assert [row['reused'] for row in trace] == [0, 4050, 4050, 4049]
assert [row['tail_reference_dc'] for row in trace] == [100, 100, 100, 103]
(args.output / 'full_input.mem').write_text(''.join(f'{value:02x}\n' for value in memory))
for name, values in (('lengths', lengths), ('values', [threshold] * 4)):
    (args.output / f'full_{name}.mem').write_text(''.join(f'{value:08x}\n' for value in values))
(args.output / 'full_expected.json').write_text(json.dumps(trace, indent=2) + '\n')
print('DDR_FULL_VECTORS_PASS: all4050 positions; tail4049 cumulative drift100,101,102,103 retains100,100,100,103')

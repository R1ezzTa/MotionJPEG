"""Early DATA rejection, late mismatch, malformed input and next-group reset."""
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
args.output.mkdir(parents=True, exist_ok=True)
quant = [int(line, 16) & 255 for line in
         (Path(__file__).resolve().parents[1] / 'data/board_test/camera_quant.mem').read_text().splitlines()][256:384]
base = header(128, 8, False, quant)
sos = base.rfind(b'\xff\xda')
base = base[:sos] + segment(0xdd, [0, 4]) + base[sos:]
config = parse_header(base)


def entropy(first_dc=100, last_ac=1):
    writer = BitWriter()
    previous = [0, 0, 0]
    for block in range(16):
        component = (0, 0, 1, 2)[block % 4]
        coefficients = [first_dc if block == 0 else 100] + [1] * 63
        if block == 15:
            coefficients[63] = last_ac
        table = 0 if component == 0 else 2
        for dc, sym, amp, count in symbols(coefficients, previous[component]):
            code, length = HUFF[table + (0 if dc else 1)][sym]
            writer.put(code, length)
            writer.put(amp, count)
        previous[component] = coefficients[0]
    return bytes(writer.finish())


normal = entropy()
early = entropy(140)
late = entropy(140, 200)
changed = entropy(180, 200)
truncated = changed[:len(changed) // 2]
if truncated[-1] == 255:
    truncated = truncated[:-1]
bad_prefix = b'\xff\x00\xff\x00'  # Nonexistent all-one Huffman code, correct stuffing.
schedule = [(normal, normal), (early, normal), (early, normal),
            (late, normal), (late, normal), (truncated, normal),
            (changed, bad_prefix), (changed, normal), (changed, normal)]
memory = []
lengths = []
trace = []
reference = None
decoder = SpatialDecoder()
for frame_id, pair in enumerate(schedule):
    groups = [pair[0] + b'\xff\xd0', pair[1] + b'\xff\xd9']
    jpeg = base + b''.join(groups)
    assert len(jpeg) <= 4096
    lengths.append(len(jpeg))
    memory.extend(jpeg + bytes(4096 - len(jpeg)))
    key = reference is None
    packet = bytearray(struct.pack('<4sBIB', b'SPJ2', key, 0xffffffff if key else frame_id - 1, 32))
    packet += struct.pack('<BH', 0, len(base)) + base
    retained = []
    reused = []
    malformed = []
    for index, group in enumerate(groups):
        copy = False
        if not key:
            try:
                copy = within_deadzone(decode_restart_group(group, config),
                                       decode_restart_group(reference[index], config), 32)
            except ValueError:
                malformed.append(index)
        if copy:
            packet += struct.pack('<BH', 2, index)
            retained.append(reference[index])
            reused.append(index)
        else:
            packet += struct.pack('<BHH', 1, index, len(group)) + group
            retained.append(group)
    reference = retained
    # SPJ reconstruction preserves original malformed entropy in DATA, just as
    # the existing cache does. Coefficient errors must never justify COPY.
    assert decoder.decode(packet, frame_id) == base + b''.join(reference)
    (args.output / f'expected_early_{frame_id}.spj').write_bytes(packet)
    trace.append(dict(frame_id=frame_id, threshold=32, keyframe=key, reused=reused,
                      malformed_comparisons=malformed, group_bytes=list(map(len, groups))))
assert [row['reused'] for row in trace] == [[], [1], [0, 1], [1], [0, 1], [1], [], [0], [0, 1]]
assert trace[5]['malformed_comparisons'] == [0]
assert trace[6]['malformed_comparisons'] == [0, 1]
assert trace[7]['malformed_comparisons'] == [1]
(args.output / 'early_input.mem').write_text(''.join(f'{value:02x}\n' for value in memory))
for name, values in (('lengths', lengths), ('values', [32] * len(schedule))):
    (args.output / f'early_{name}.mem').write_text(''.join(f'{value:08x}\n' for value in values))
(args.output / 'early_expected.json').write_text(json.dumps(trace, indent=2) + '\n')
print('DDR_EARLY_VECTORS_PASS: dense DC/last-coefficient mismatch, truncated suffix, malformed reference/current, subsequent COPY')

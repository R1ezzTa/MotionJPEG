"""Independent entropy vectors and expected retained references for RTL dead zone."""
import argparse
import json
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_coefficients import parse_header, decode_restart_group, within_deadzone
from spatial_jpeg import SpatialDecoder
from spatial_reference import BitWriter, HUFF, header, segment, symbols


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    quant = [int(line, 16) & 255 for line in (Path(__file__).resolve().parents[1] / 'data/board_test/camera_quant.mem').read_text().splitlines()][256:384]
    base = header(128, 8, False, quant)
    sos = base.rfind(b'\xff\xda')
    base = base[:sos] + segment(0xdd, [0, 4]) + base[sos:]
    config = parse_header(base)
    threshold = min(255, quant[0] * 2)
    # Same threshold across frames2..5: differences1/2 held; cumulative3 updates.
    schedule = [(0,0),(0,1),(threshold,0),(threshold,1),(threshold,2),(threshold,3),
                (threshold,3),(0,4),(0,4),(255,0),(255,1),(255,1)]
    memory, lengths, thresholds, trace = [], [], [], []
    reference = None
    previous_threshold = None
    decoder = SpatialDecoder()
    for frame_id, (t, change) in enumerate(schedule):
        groups = []
        for region in range(2):
            writer = BitWriter(); previous = [0,0,0]
            for block in range(16):
                component = (0,0,1,2)[block % 4]
                coefficients = [0] * 64
                coefficients[0] = (100 if component == 0 else 20) + (change if region == 0 and block == 0 else 0)
                coefficients[3] = 1 if block == 2 else 0
                if frame_id == 6 and region == 1 and block == 0:
                    coefficients[63] = 40  # Isolated high-frequency change must update.
                table = 0 if component == 0 else 2
                for dc, sym, amp, n in symbols(coefficients, previous[component]):
                    code, bits = HUFF[table + (0 if dc else 1)][sym]
                    writer.put(code, bits); writer.put(amp, n)
                previous[component] = coefficients[0]
            groups.append(writer.finish() + (b'\xff\xd0' if region == 0 else b'\xff\xd9'))
        jpeg = base + b''.join(groups)
        lengths.append(len(jpeg)); thresholds.append(t)
        memory.extend(jpeg + bytes(1024-len(jpeg)))
        key = reference is None or t != previous_threshold
        out = bytearray(struct.pack('<4sBIB', b'SPJ2', key, 0xffffffff if key else frame_id-1, t))
        out += struct.pack('<BH', 0, len(base)) + base
        next_reference, reused = [], []
        for i, group in enumerate(groups):
            copy = not key and (group == reference[i] if t == 0 else within_deadzone(
                decode_restart_group(group, config), decode_restart_group(reference[i], config), t))
            if copy:
                out += struct.pack('<BH', 2, i); next_reference.append(reference[i]); reused.append(i)
            else:
                out += struct.pack('<BHH', 1, i, len(group)) + group; next_reference.append(group)
        reference = next_reference; previous_threshold = t
        restored = decoder.decode(bytes(out), frame_id)
        assert restored == base + b''.join(reference)
        (args.output / f'expected_threshold_{frame_id}.spj').write_bytes(out)
        trace.append(dict(frame_id=frame_id, threshold=t, keyframe=key, reused=reused, bytes=len(out)))
    assert trace[3]['reused'] == trace[4]['reused'] == [0,1]
    assert trace[5]['reused'] == [1] and trace[6]['reused'] == [0]
    (args.output / 'threshold_input.mem').write_text(''.join(f'{b:02x}\n' for b in memory))
    for name, values in [('lengths',lengths),('values',thresholds)]:
        (args.output / f'threshold_{name}.mem').write_text(''.join(f'{v:08x}\n' for v in values))
    (args.output / 'threshold_expected.json').write_text(json.dumps(trace, indent=2))
    print(f'THRESHOLD_VECTORS_PASS: {len(trace)} frames, retained-reference drift and coefficient63')


if __name__ == '__main__': main()

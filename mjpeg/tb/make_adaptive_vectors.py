"""Independent coefficient/reference model for the board adaptive experiment."""
import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_coefficients import decode_restart_group, parse_header
from spatial_jpeg import SpatialDecoder
from spatial_reference import BitWriter, HUFF, header, segment, symbols


def entropy(ac=0, dc=0, chroma=0, dense=False):
    writer = BitWriter()
    previous = [0, 0, 0]
    for block in range(16):
        component = (0, 0, 1, 2)[block % 4]
        coefficients = [100] + [0] * 63
        if block == 0:
            coefficients[0] += dc
            coefficients[20] = ac
        if block == 2:
            coefficients[0] += chroma
        if dense and component == 0:
            coefficients[6:] = [1] * 58
        table = 0 if component == 0 else 2
        for is_dc, sym, amp, count in symbols(coefficients, previous[component]):
            code, length = HUFF[table + (0 if is_dc else 1)][sym]
            writer.put(code, length)
            writer.put(amp, count)
        previous[component] = coefficients[0]
    return bytes(writer.finish())


def compare(current, reference, config, ceiling):
    a, b = decode_restart_group(current, config), decode_restart_group(reference, config)
    differences = []
    protected = []
    for ca, cb in zip(a.blocks, b.blocks):
        for position, (x, y) in enumerate(zip(ca.dequantized_coefficients, cb.dequantized_coefficients)):
            delta = abs(x - y)
            differences.append(delta)
            if position < 6 or ca.component_id != 1:
                protected.append(delta)
    safe = max(differences, default=0) <= ceiling and max(protected, default=0) <= ceiling // 2
    safe = safe and sum(differences) <= ceiling * 64
    return safe, max(differences, default=0), sum(differences)


def generate(output, name, count, force_data=False, queued=False):
    quant = [int(line, 16) & 255 for line in
             (Path(__file__).resolve().parents[1] / 'data/board_test/camera_quant.mem').read_text().splitlines()][256:384]
    base = header(64 * count, 8, False, quant) if count == 2 else header(1920, 1080, False, quant)
    sos = base.rfind(b'\xff\xda')
    base = base[:sos] + segment(0xdd, [0, 4]) + base[sos:]
    config = parse_header(base)
    # Stable high-frequency changes exercise learning; DC/chroma changes and
    # many individually small AC changes must select DATA. Modes/caps refresh.
    schedule = [(1, 60, 0, 0, 0, False), (1, 60, 4, 0, 0, False),
                (1, 60, 0, 0, 0, False), (1, 60, 0, 0, 0, False),
                (1, 60, 4, 0, 0, False), (1, 60, 0, 0, 0, False),
                (1, 60, 0, 0, 0, False), (1, 60, 0, 0, 0, False),
                (1, 60, 0, 8, 0, False), (1, 60, 0, 8, 0, False),
                (1, 60, 0, 8, 8, False), (1, 60, 0, 8, 8, True),
                (1, 60, 0, 8, 8, False), (0, 60, 0, 8, 8, False),
                (0, 60, 4, 8, 8, False), (1, 60, 4, 8, 8, False),
                (1, 0, 4, 8, 8, False), (1, 0, 4, 8, 8, False),
                (1, 32, 4, 8, 8, False), (1, 32, 0, 8, 8, False)]
    if count == 4050:
        schedule = schedule[:8]
    stride = 4096 if count == 2 else 262144
    reference = None
    metadata = [(0, 0)] * count
    decoder = SpatialDecoder()
    trace, lengths, memory = [], [], bytearray()
    last_mode = last_ceiling = None
    for frame_id, (automatic, ceiling, ac, dc, chroma, dense) in enumerate(schedule):
        stable, varying = entropy(), entropy(ac, dc, chroma, dense)
        groups = [(varying if index == count - 1 else stable) +
                  bytes([255, 0xd9 if index == count - 1 else 0xd0 + index % 8]) for index in range(count)]
        jpeg = base + b''.join(groups)
        assert len(jpeg) <= stride
        lengths.append(len(jpeg));memory.extend(jpeg + bytes(stride - len(jpeg)))
        key = reference is None or automatic != last_mode or ceiling != last_ceiling
        packet = bytearray(struct.pack('<4sBIB', b'SPJ2', int(key) | automatic * 2,
                                      0xffffffff if key else frame_id - 1, ceiling))
        packet += struct.pack('<BH', 0, len(base)) + base
        retained, next_metadata, copied, details = [], [], [], {}
        for index, current in enumerate(groups):
            level, age = metadata[index]
            tolerance = (ceiling // 4, ceiling // 2, ceiling - ceiling // 4, ceiling)[level]
            copy = False
            next_level = next_age = 0
            if not key:
                if automatic and ceiling:
                    # The dense final region takes longer to ingest than the
                    # first flat region takes to compare, so that fixture does
                    # not create a queue backlog for position zero.
                    if force_data or (queued and index < count - 1 and not dense):
                        reason = 'budget refresh'
                    elif age == 2:
                        next_level = level
                        reason = 'age refresh'
                    else:
                        safe, peak, total = compare(current, reference[index], config, ceiling)
                        copy = safe and peak <= tolerance
                        next_level = min(3, level + 1) if safe else 0
                        next_age = age + 1 if copy else 0
                        reason = 'copy' if copy else ('learning' if safe else 'protected change')
                        details[index] = dict(peak=peak, total=total, safe=safe, reason=reason)
                elif ceiling == 0:
                    copy = current == reference[index]
                else:
                    _, peak, _ = compare(current, reference[index], config, ceiling)
                    copy = peak <= ceiling
            if copy:
                packet += struct.pack('<BH', 2, index)
                retained.append(reference[index]);copied.append(index)
            else:
                packet += struct.pack('<BHH', 1, index, len(current)) + current
                retained.append(current)
            next_metadata.append((next_level, next_age))
        reconstructed = decoder.decode(packet, frame_id)
        assert reconstructed == base + b''.join(retained)
        (output / f'expected_{name}_{frame_id}.spj').write_bytes(packet)
        trace.append(dict(frame=frame_id, adaptive=automatic, ceiling=ceiling, keyframe=key,
                          copies=len(copied), last_copied=count - 1 in copied,
                          last_metadata=next_metadata[-1], last_comparison=details.get(count - 1)))
        reference, metadata = retained, next_metadata
        last_mode, last_ceiling = automatic, ceiling
    if not force_data:
        assert trace[1]['last_comparison']['reason'] == 'learning'
        assert trace[2]['last_copied'] and trace[3]['last_copied'] and not trace[4]['last_copied']
    if count == 2 and not force_data:
        assert not trace[8]['last_copied'] and not trace[10]['last_copied']
        assert trace[11]['last_comparison']['total'] > 60 * 64 and not trace[11]['last_copied']
        assert all(trace[i]['keyframe'] for i in (0, 13, 15, 16, 18))
        assert trace[17]['copies'] == count
    (output / f'{name}_input.mem').write_text(''.join(f'{x:02x}\n' for x in memory))
    for suffix, values in [('lengths', lengths), ('values', [s[1] for s in schedule]), ('modes', [s[0] for s in schedule])]:
        (output / f'{name}_{suffix}.mem').write_text(''.join(f'{x:08x}\n' for x in values))
    (output / f'{name}_expected.json').write_text(json.dumps(trace, indent=2) + '\n')
    print(f'{name}: {len(schedule)} frames, {count} regions, independent reference ready')


if __name__ == '__main__':
    parser = argparse.ArgumentParser();parser.add_argument('output', type=Path)
    args = parser.parse_args();args.output.mkdir(parents=True, exist_ok=True)
    generate(args.output, 'adaptive', 2)
    generate(args.output, 'adaptive_full', 4050)
    generate(args.output, 'adaptive_budget', 2, force_data=True)
    generate(args.output, 'adaptive_queue', 2, queued=True)
    generate(args.output, 'adaptive_pressure', 2, force_data=True)

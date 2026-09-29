"""Offline experiment: preserve JPEG quantized coefficients, add restart groups.

This is an analysis tool for this project's fixed Baseline Huffman tables, not a
real-time encoder and not a claim of lower USB traffic on existing firmware.
"""
import argparse
import io
import json
import struct
import sys
from pathlib import Path
from PIL import Image
from spatial_reference import BitWriter, HUFF, header, segment, symbols, ZZ
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from block_records import BlockRecords
from spatial_jpeg import SpatialEncoder, SpatialDecoder, split_jpeg, MAGIC, NONE


class Bits:
    def __init__(self, data):
        self.data = data.replace(b'\xff\x00', b'\xff')
        self.position = self.acc = self.count = 0

    def get(self, n):
        while self.count < n:
            if self.position >= len(self.data): raise ValueError('Truncated entropy')
            self.acc = self.acc << 8 | self.data[self.position]
            self.count += 8
            self.position += 1
        self.count -= n
        result = self.acc >> self.count & ((1 << n) - 1)
        self.acc &= (1 << self.count) - 1
        return result


DECODE = [{(code, n): symbol for symbol, (code, n) in table.items()} for table in HUFF]


def symbol(reader, table):
    code = 0
    for n in range(1, 17):
        code = code << 1 | reader.get(1)
        value = table.get((code, n))
        if value is not None: return value
    raise ValueError('Invalid Huffman code')


def receive(reader, n):
    value = reader.get(n)
    return value if not n or value >= 1 << (n - 1) else value - ((1 << n) - 1)


def add_restart(jpeg, interval=4):
    # Project header has fixed table layout; insist on an exact header match.
    if jpeg[:2] != b'\xff\xd8' or jpeg[-2:] != b'\xff\xd9': raise ValueError('JPEG boundary')
    sof = jpeg.index(b'\xff\xc0')
    h, w = struct.unpack_from('>HH', jpeg, sof + 5)
    gray = jpeg[sof + 9] == 1
    qs = [0] * 128
    for k, position in enumerate(ZZ):
        qs[position] = jpeg[25 + k]
        qs[64 + position] = jpeg[90 + k]
    original_header = header(w, h, gray, qs)
    if not jpeg.startswith(original_header): raise ValueError('Unsupported source JPEG header/tables')
    if w % ((8 if gray else 16) * interval) or h % 8: raise ValueError('Geometry')
    sos = original_header.rfind(b'\xff\xda')
    out = bytearray(original_header[:sos] + segment(0xdd, [interval >> 8, interval & 255]) + original_header[sos:])
    reader = Bits(jpeg[len(original_header):-2])
    source_previous = [0, 0, 0]
    previous = [0, 0, 0]
    writer = BitWriter()
    total = w // (8 if gray else 16) * (h // 8)
    restart = 0
    for mcu in range(total):
        for component in ((0,) if gray else (0, 0, 1, 2)):
            table_index = 0 if component == 0 else 2
            category = symbol(reader, DECODE[table_index])
            if category > 11: raise ValueError('DC category')
            source_previous[component] += receive(reader, category)
            coefficients = [source_previous[component]] + [0] * 63
            k = 1
            while k < 64:
                ac = symbol(reader, DECODE[table_index + 1])
                if ac == 0: break
                if ac == 0xf0:
                    k += 16
                    if k > 64: raise ValueError('ZRL')
                    continue
                k += ac >> 4
                if k >= 64 or not 1 <= (ac & 15) <= 10: raise ValueError('AC category/run')
                coefficients[k] = receive(reader, ac & 15)
                k += 1
            for dc, sym, amp, n in symbols(coefficients, previous[component]):
                code, length = HUFF[table_index + (0 if dc else 1)][sym]
                writer.put(code, length)
                writer.put(amp, n)
            previous[component] = coefficients[0]
        if (mcu + 1) % interval == 0 and mcu + 1 < total:
            out += writer.finish() + bytes([255, 0xd0 + (restart & 7)])
            writer = BitWriter()
            previous = [0, 0, 0]
            restart += 1
    return bytes(out + writer.finish() + b'\xff\xd9')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--frames', type=int, default=6)
    parser.add_argument('--skip', type=int, default=60)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    encoder, decoder = SpatialEncoder(), SpatialDecoder()
    limited_decoder = SpatialDecoder()
    previous = None
    result = []
    count = 0
    with args.capture.open('rb') as source:
        records = BlockRecords(source.read)
        while len(result) < args.frames:
            kind, frame = records.next()
            if kind != 'frame' or frame.status: continue
            count += 1
            if count <= args.skip: continue
            restarted = add_restart(frame.jpeg)
            with Image.open(io.BytesIO(restarted)) as a, Image.open(io.BytesIO(frame.jpeg)) as b:
                assert a.convert('RGB').tobytes() == b.convert('RGB').tobytes(), 'Transcoder changed pixels'
            index = len(result)
            packet = encoder.encode(restarted, index)
            assert decoder.decode(packet, index) == restarted
            current = split_jpeg(restarted)
            limited = bytearray(struct.pack('<4sBI', MAGIC, int(previous is None), NONE if previous is None else index - 1))
            limited += struct.pack('<BH', 0, len(current.header)) + current.header
            for k, group in enumerate(current.groups):
                eligible = k % 21 == 0 and k // 21 < 192 and len(group) <= 256
                if previous is not None and eligible and group == previous.groups[k] and len(previous.groups[k]) <= 256:
                    limited += struct.pack('<BH', 2, k)
                else:
                    limited += struct.pack('<BHH', 1, k, len(group)) + group
            assert limited_decoder.decode(bytes(limited), index) == restarted
            result.append(dict(source_frame_id=frame.frame_id, original_jpeg_bytes=len(frame.jpeg),
                               full_cache=decoder.last_stats, board_cache=limited_decoder.last_stats))
            previous = current
            print(f'Frame {frame.frame_id}: full cache reused {decoder.last_stats["reused"]}/{len(current.groups)}, board cache {limited_decoder.last_stats["reused"]}', flush=True)
    original = sum(f['original_jpeg_bytes'] for f in result)
    summary = dict(passed=True, source=str(args.capture.resolve()), frames=result, original_bytes=original)
    for mode in ('full_cache', 'board_cache'):
        size = sum(f[mode]['transport_bytes'] for f in result)
        summary[mode] = dict(bytes=size, reduction_vs_original=1-size/original)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != 'frames'}))


if __name__ == '__main__': main()

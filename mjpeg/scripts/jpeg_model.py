"""Independent integer JPEG encoder model; RTL is written separately.

Only numerical tables from ITU-T T.81 Annex K are used. No codec source/IP.
Pillow is used only as an independent decoder in verification.
"""

import math, io, json
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ZZ = [
    0,
    1,
    8,
    16,
    9,
    2,
    3,
    10,
    17,
    24,
    32,
    25,
    18,
    11,
    4,
    5,
    12,
    19,
    26,
    33,
    40,
    48,
    41,
    34,
    27,
    20,
    13,
    6,
    7,
    14,
    21,
    28,
    35,
    42,
    49,
    56,
    57,
    50,
    43,
    36,
    29,
    22,
    15,
    23,
    30,
    37,
    44,
    51,
    58,
    59,
    52,
    45,
    38,
    31,
    39,
    46,
    53,
    60,
    61,
    54,
    47,
    55,
    62,
    63,
]
QY = [
    16,
    11,
    10,
    16,
    24,
    40,
    51,
    61,
    12,
    12,
    14,
    19,
    26,
    58,
    60,
    55,
    14,
    13,
    16,
    24,
    40,
    57,
    69,
    56,
    14,
    17,
    22,
    29,
    51,
    87,
    80,
    62,
    18,
    22,
    37,
    56,
    68,
    109,
    103,
    77,
    24,
    35,
    55,
    64,
    81,
    104,
    113,
    92,
    49,
    64,
    78,
    87,
    103,
    121,
    120,
    101,
    72,
    92,
    95,
    98,
    112,
    100,
    103,
    99,
]
QC = [
    17,
    18,
    24,
    47,
    99,
    99,
    99,
    99,
    18,
    21,
    26,
    66,
    99,
    99,
    99,
    99,
    24,
    26,
    56,
    99,
    99,
    99,
    99,
    99,
    47,
    66,
    99,
    99,
    99,
    99,
    99,
    99,
] + [99] * 32
BITS = [
    [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
    [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125],
    [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
    [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119],
]
VALS = [
    list(range(12)),
    list(
        bytes.fromhex(
            """
01 02 03 00 04 11 05 12 21 31 41 06 13 51 61 07
22 71 14 32 81 91 A1 08 23 42 B1 C1 15 52 D1 F0
24 33 62 72 82 09 0A 16 17 18 19 1A 25 26 27 28
29 2A 34 35 36 37 38 39 3A 43 44 45 46 47 48 49
4A 53 54 55 56 57 58 59 5A 63 64 65 66 67 68 69
6A 73 74 75 76 77 78 79 7A 83 84 85 86 87 88 89
8A 92 93 94 95 96 97 98 99 9A A2 A3 A4 A5 A6 A7
A8 A9 AA B2 B3 B4 B5 B6 B7 B8 B9 BA C2 C3 C4 C5
C6 C7 C8 C9 CA D2 D3 D4 D5 D6 D7 D8 D9 DA E1 E2
E3 E4 E5 E6 E7 E8 E9 EA F1 F2 F3 F4 F5 F6 F7 F8
F9 FA"""
        )
    ),
    list(range(12)),
    list(
        bytes.fromhex(
            """
00 01 02 03 11 04 05 21 31 06 12 41 51 07 61 71
13 22 32 81 08 14 42 91 A1 B1 C1 09 23 33 52 F0
15 62 72 D1 0A 16 24 34 E1 25 F1 17 18 19 1A 26
27 28 29 2A 35 36 37 38 39 3A 43 44 45 46 47 48
49 4A 53 54 55 56 57 58 59 5A 63 64 65 66 67 68
69 6A 73 74 75 76 77 78 79 7A 82 83 84 85 86 87
88 89 8A 92 93 94 95 96 97 98 99 9A A2 A3 A4 A5
A6 A7 A8 A9 AA B2 B3 B4 B5 B6 B7 B8 B9 BA C2 C3
C4 C5 C6 C7 C8 C9 CA D2 D3 D4 D5 D6 D7 D8 D9 DA
E2 E3 E4 E5 E6 E7 E8 E9 EA F2 F3 F4 F5 F6 F7 F8
F9 FA"""
        )
    ),
]


def canonical(bits, vals):
    code = 0
    k = 0
    result = {}
    for length, count in enumerate(bits, 1):
        for _ in range(count):
            assert code < (1 << length) - 1
            result[vals[k]] = (code, length)
            k += 1
            code += 1
        code <<= 1
    assert k == len(vals)
    return result


HUFF = [canonical(b, v) for b, v in zip(BITS, VALS)]
C = np.array(
    [
        [
            round(
                4096
                * 0.5
                * (1 / math.sqrt(2) if u == 0 else 1)
                * math.cos((2 * n + 1) * u * math.pi / 16)
            )
            for n in range(8)
        ]
        for u in range(8)
    ],
    dtype=np.int64,
)


def rshift(a, n):
    return np.where(a < 0, -((-a + (1 << (n - 1))) >> n), (a + (1 << (n - 1))) >> n)


def dct(block):
    rows = rshift((block.astype(np.int64) - 128) @ C.T, 8)
    return rshift(C @ rows, 16)


def tables(quality):
    assert 1 <= quality <= 100
    scale = 5000 // quality if quality < 50 else 200 - quality * 2
    return [max(1, min(255, (q * scale + 50) // 100)) for q in QY + QC]


def segment(marker, payload):
    return (
        bytes([255, marker])
        + bytes([(len(payload) + 2) >> 8, (len(payload) + 2) & 255])
        + bytes(payload)
    )


def header(w, h, gray, qs):
    out = bytearray(b"\xff\xd8")
    out += segment(0xE0, bytes.fromhex("4a46494600010100000100010000"))
    out += segment(0xDB, [0] + [qs[i] for i in ZZ] + [1] + [qs[64 + i] for i in ZZ])
    out += segment(
        0xC0,
        [8, h >> 8, h & 255, w >> 8, w & 255, 1 if gray else 3, 1, 0x11 if gray else 0x21, 0]
        + ([] if gray else [2, 0x11, 1, 3, 0x11, 1]),
    )
    dht = []
    for ident, b, v in zip([0, 0x10, 1, 0x11], BITS, VALS):
        dht += [ident] + b + v
    out += segment(0xC4, dht)
    out += segment(
        0xDA, [1 if gray else 3, 1, 0] + ([] if gray else [2, 0x11, 3, 0x11]) + [0, 63, 0]
    )
    return bytes(out)


class BitWriter:
    def __init__(self):
        self.acc = 0
        self.n = 0
        self.out = bytearray()

    def put(self, b, n):
        self.acc = (self.acc << n) | b
        self.n += n
        while self.n >= 8:
            self.n -= 8
            byte = (self.acc >> self.n) & 255
            self.out.append(byte)
            if byte == 255:
                self.out.append(0)
        self.acc &= (1 << self.n) - 1

    def finish(self):
        if self.n:
            self.put((1 << (8 - self.n)) - 1, 8 - self.n)
        return self.out


def symbols(coeffs, prev):
    dc = int(coeffs[0])
    diff = dc - prev
    size = abs(diff).bit_length()
    yield True, size, (diff if diff >= 0 else diff - 1) & ((1 << size) - 1), size
    run = 0
    for k, v in enumerate(coeffs[1:], 1):
        v = int(v)
        if v == 0:
            run += 1
            if k == 63:
                yield False, 0, 0, 0
        else:
            while run >= 16:
                yield False, 0xF0, 0, 0
                run -= 16
            size = abs(v).bit_length()
            assert size <= 10
            yield False, (run << 4) | size, (v if v > 0 else v - 1) & ((1 << size) - 1), size
            run = 0


def blocks(y, cb, cr, gray):
    h, w = y.shape
    for row in range(0, h, 8):
        for col in range(0, w, 8 if gray else 16):
            yield 0, y[row : row + 8, col : col + 8]
            if not gray:
                yield 0, y[row : row + 8, col + 8 : col + 16]
                yield 1, cb[row : row + 8, col // 2 : col // 2 + 8]
                yield 2, cr[row : row + 8, col // 2 : col // 2 + 8]


def encode(y, cb, cr, gray, qs):
    h, w = y.shape
    writer = BitWriter()
    last = [0] * 3
    for comp, block in blocks(y, cb, cr, gray):
        co = dct(block).reshape(64)
        qt = np.array(qs[0:64] if comp == 0 else qs[64:128])
        quant = np.sign(co) * ((np.abs(co) + qt // 2) // qt)
        scan = quant[ZZ]
        for dc, sym, amp, size in symbols(scan, last[comp]):
            code, n = HUFF[(0 if comp == 0 else 2) + (0 if dc else 1)][sym]
            writer.put(code, n)
            writer.put(amp, size)
        last[comp] = int(scan[0])
    return header(w, h, gray, qs) + writer.finish() + b"\xff\xd9"


def generate_constants():
    out = [
        "// Generated by scripts/jpeg_model.py from T.81 numerical tables.",
        "function [5:0] zigzag; input [5:0] k; begin case(k)",
    ]
    out += [f"6'd{i}: zigzag=6'd{v};" for i, v in enumerate(ZZ)]
    out += ["default: zigzag=0; endcase end endfunction"]
    (ROOT / "rtl/generated/zigzag.vh").write_text("\n".join(out) + "\n")
    out = ["function [20:0] huffman; input [9:0] key; begin case(key)"]
    for t, table in enumerate(HUFF):
        for sym, (code, n) in table.items():
            out.append(f"10'h{t*256+sym:03x}: huffman={{5'd{n},16'h{code:04x}}};")
    out += ["default: huffman=0; endcase end endfunction"]
    (ROOT / "rtl/generated/huffman.vh").write_text("\n".join(out) + "\n")
    # ROM includes dynamic DQT, dimensions, sampling and scan component count.
    hg = header(1920, 1080, True, list(range(64)) * 2)
    hc = header(1920, 1080, False, list(range(64)) * 2)
    # Use two separate address spaces so gray and colour headers need no fragile offsets.
    entries = {}
    for gray, template, offset in [(True, hg, 0), (False, hc, 1024)]:
        sof = template.index(b"\xff\xc0")
        for i, b in enumerate(template):
            dynamic = {
                sof + 5: "frame_height[15:8]",
                sof + 6: "frame_height[7:0]",
                sof + 7: "frame_width[15:8]",
                sof + 8: "frame_width[7:0]",
            }
            if 25 <= i <= 88 or 90 <= i <= 153:
                val = "q_read_data"
            else:
                val = dynamic.get(i, f"8'h{b:02x}")
            entries[offset + i] = val
    # Split into 32-byte segments. The hardware registers all segment
    # candidates, then selects the registered bank in a separate cycle.
    out = ["// Generated segmented header ROM; dynamic values sampled at lookup."]
    for bank in range(64):
        fn = f"header_part_{bank}"
        out.append(
            f"function [7:0] {fn}; input [4:0] addr; input [15:0] frame_width,frame_height; input [7:0] q_read_data; begin case(addr)"
        )
        for i in range(32):
            if bank * 32 + i in entries:
                out.append(f"5'd{i}: {fn}={entries[bank*32+i]};")
        out.append(f"default: {fn}=0; endcase end endfunction")
    out.append(
        "function [511:0] header_lookup; input [4:0] addr; input [15:0] frame_width,frame_height; input [7:0] q_read_data; begin"
    )
    for bank in range(64):
        out.append(
            f"header_lookup[{bank*8}+:8]=header_part_{bank}(addr,frame_width,frame_height,q_read_data);"
        )
    out.append("end endfunction")
    (ROOT / "rtl/generated/header.vh").write_text("\n".join(out) + "\n")
    return len(hg), len(hc)


def make_fixtures():
    cases = [
        ("gray_zero", 8, 8, True, 75, "zero"),
        ("gray_ramp", 16, 16, True, 85, "ramp"),
        ("gray_noise", 32, 24, True, 100, "noise"),
        ("color_mcu", 16, 8, False, 85, "ramp"),
        ("color_flat", 16, 8, False, 75, "flat"),
        ("color_noise", 32, 24, False, 90, "noise"),
        ("wide", 1920, 16, False, 75, "ramp"),
        ("tall", 32, 1080, False, 85, "ramp"),
        ("fhd", 1920, 1080, False, 85, "ramp"),
    ]
    manifest = []
    rng = np.random.default_rng(12345)
    for name, w, h, gray, q, pattern in cases:
        yy, xx = np.indices((h, w))
        y = (
            np.full((h, w), 128, dtype=np.uint8)
            if pattern == "zero"
            else ((xx * 3 + yy * 2) & 255).astype(np.uint8)
        )
        if pattern == "noise":
            y = rng.integers(0, 256, (h, w), dtype=np.uint8)
        cb = ((np.indices((h, w // 2))[1] * 2 + np.indices((h, w // 2))[0] + 80) & 255).astype(
            np.uint8
        )
        cr = ((np.indices((h, w // 2))[1] + np.indices((h, w // 2))[0] * 3 + 160) & 255).astype(
            np.uint8
        )
        if pattern == "noise":
            cb = rng.integers(0, 256, (h, w // 2), dtype=np.uint8)
            cr = rng.integers(0, 256, (h, w // 2), dtype=np.uint8)
        if pattern == "flat":
            y[:] = 96
            cb[:] = 80
            cr[:] = 176
        qs = tables(q)
        jpg = encode(y, cb, cr, gray, qs)
        d = ROOT / "data" / name
        d.mkdir(exist_ok=True)
        chrom = np.empty((h, w), dtype=np.uint16)
        chrom[:, ::2] = cb
        chrom[:, 1::2] = cr
        words = y.astype(np.uint16) | (chrom << 8)
        (d / "pixels.mem").write_text("".join(f"{v:04x}\n" for v in words.reshape(-1)))
        (d / "expected.mem").write_text("".join(f"{v:02x}\n" for v in jpg))
        (d / "quant.mem").write_text("".join(f"{((1<<20)+v-1)//v:06x}{v:02x}\n" for v in qs))
        (d / "model.jpg").write_bytes(jpg)
        decoded = Image.open(io.BytesIO(jpg))
        decoded.load()
        assert decoded.size == (w, h)
        if pattern == "flat":
            reference = np.array(
                Image.fromarray(np.array([[[96, 80, 176]]], dtype=np.uint8), "YCbCr").convert("RGB")
            )[0, 0]
            assert np.max(np.abs(np.array(decoded).astype(int) - reference.astype(int))) <= 2
        dec_y = (
            np.array(decoded if gray else decoded.convert("YCbCr"))
            if gray
            else np.array(decoded.convert("YCbCr"))[:, :, 0]
        )
        mse = float(np.mean((dec_y.astype(float) - y.astype(float)) ** 2))
        psnr = 99 if mse == 0 else 10 * math.log10(255**2 / mse)
        manifest.append(
            dict(
                name=name,
                width=w,
                height=h,
                gray=int(gray),
                quality=q,
                bytes=len(jpg),
                luma_psnr=round(psnr, 2),
                stuffed=jpg[len(header(w, h, gray, qs)) : -2].count(b"\xff\x00"),
            )
        )
        print(name, w, h, len(jpg), round(psnr, 2), flush=True)
    (ROOT / "data/manifest.json").write_text(json.dumps(manifest, indent=2))
    (ROOT / "data/cases.txt").write_text(
        "".join(
            f"{c['name']} {c['width']} {c['height']} {c['gray']} {c['bytes']}\n" for c in manifest
        )
    )


if __name__ == "__main__":
    import sys

    sys.stdout.reconfigure(encoding="utf-8")
    print("header lengths", generate_constants())
    make_fixtures()

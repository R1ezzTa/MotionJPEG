"""Independent numerical encoder for restart JPEG; existing model stays intact."""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'xilinx_mjpeg/scripts'))
from jpeg_model import BitWriter, blocks, dct, HUFF, ZZ, header, segment, symbols


def encode_restart(y, cb, cr, gray, qs, interval=4):
    h, w = y.shape
    original = header(w, h, gray, qs)
    sos = original.rfind(b'\xff\xda')
    out = bytearray(original[:sos] + segment(0xdd, [interval >> 8, interval & 255]) + original[sos:])
    writer = BitWriter()
    previous = [0, 0, 0]
    per_mcu = 1 if gray else 4
    count = 0
    restart = 0
    total = w // (8 if gray else 16) * (h // 8)
    for comp, block in blocks(y, cb, cr, gray):
        co = dct(block).reshape(64)
        qt = np.array(qs[:64] if comp == 0 else qs[64:])
        scan = (np.sign(co) * ((np.abs(co) + qt // 2) // qt))[ZZ]
        for dc, sym, amp, size in symbols(scan, previous[comp]):
            code, n = HUFF[(0 if comp == 0 else 2) + (0 if dc else 1)][sym]
            writer.put(code, n)
            writer.put(amp, size)
        previous[comp] = int(scan[0])
        count += 1
        if count % (interval * per_mcu) == 0 and count // per_mcu < total:
            out += writer.finish() + bytes([255, 0xd0 + (restart & 7)])
            writer = BitWriter()
            previous = [0, 0, 0]
            restart += 1
    return bytes(out + writer.finish() + b'\xff\xd9')

"""Reproducible Q60/Q75/Q85 FPGA quantizer ROM and small independent JPEGs."""
import sys
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from jpeg_model import tables, encode


def main():
    entries = []
    y, x = np.indices((16, 48))
    cy, cx = np.indices((16, 24))
    for quality in (60, 75, 85):
        quant = tables(quality)
        entries.extend(f'{((((1 << 20) + value - 1) // value) << 8) | value:08x}\n'
                       for value in quant)
        jpg = bytes(encode(((3*x + 2*y) & 255).astype(np.uint8),
                           ((2*cx + cy + 80) & 255).astype(np.uint8),
                           ((cx + 3*cy + 160) & 255).astype(np.uint8), False, quant))
        (ROOT / f'data/progressive_test/48x16.q{quality}.expected.jpg').write_bytes(jpg)
    (ROOT / 'data/board_test/camera_quant.mem').write_text(''.join(entries), encoding='ascii')
    assert tables(85) == [int(line, 16) & 255 for line in
                         (ROOT / 'data/board_test/quant.mem').read_text().splitlines()[:128]]
    print('CAMERA_QUALITY_ROM_PASS: 384 quantizer/reciprocal entries; Q60/Q75/Q85')


if __name__ == '__main__':
    main()

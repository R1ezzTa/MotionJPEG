import io
import json
import sys
from pathlib import Path
import numpy as np
from PIL import Image
from spatial_reference import encode_restart
from jpeg_model import encode, tables
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_jpeg import SpatialEncoder, SpatialDecoder, split_jpeg


def verify(directory):
    directory = Path(directory)
    rows, cols = np.indices((24, 128))
    cy, cx = np.indices((24, 64))
    base = ((3 * cols + 2 * rows) & 255).astype(np.uint8)
    cb = ((2 * cx + cy + 80) & 255).astype(np.uint8)
    cr = ((cx + 3 * cy + 160) & 255).astype(np.uint8)
    encoder, decoder = SpatialEncoder(), SpatialDecoder()
    rtl_decoder = SpatialDecoder()
    summary = []
    previous = None
    for i in range(4):
        y = base.copy()
        if i == 2:
            y[:8, :64] = (y[:8, :64].astype(np.uint16) + 17).astype(np.uint8)
        qs = tables(60 if i == 3 else 85)
        expected = encode_restart(y, cb, cr, False, qs)
        actual = (directory / f'restart_{i}.jpg').read_bytes()
        assert actual == expected, f'RTL differs from independent restart encoder: {i}'
        with Image.open(io.BytesIO(actual)) as a, Image.open(io.BytesIO(encode(y, cb, cr, False, qs))) as b:
            assert a.convert('RGB').tobytes() == b.convert('RGB').tobytes(), 'Restart changed decoded image'
        parsed = split_jpeg(actual)
        assert [parsed.rectangle(k) for k in range(6)] == [
            (0, 0, 64, 8), (64, 0, 64, 8), (0, 8, 64, 8),
            (64, 8, 64, 8), (0, 16, 64, 8), (64, 16, 64, 8)]
        if i == 2:
            assert [k for k, (a, b) in enumerate(zip(previous.groups, parsed.groups)) if a != b] == [0]
        packet = encoder.encode(actual, i)
        assert decoder.decode(packet, i) == actual
        summary.append(dict(frame_id=i, **decoder.last_stats))
        assert rtl_decoder.decode((directory / f'spatial_{i}.spj').read_bytes(), i) == actual
        summary[-1]['rtl'] = rtl_decoder.last_stats
        previous = parsed
    assert summary[1]['reused'] == 6 and summary[2]['reused'] == 5 and summary[3]['keyframe']
    assert summary[1]['rtl']['reused'] == 3 and summary[2]['rtl']['reused'] == 2
    assert summary[3]['rtl']['keyframe']
    (directory / 'spatial_summary.json').write_text(json.dumps(dict(passed=True, frames=summary), indent=2))
    print(json.dumps(dict(passed=True, frames=summary)))


if __name__ == '__main__':
    verify(sys.argv[1])

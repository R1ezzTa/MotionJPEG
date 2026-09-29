import io
import json
import sys
from pathlib import Path
import numpy as np
from PIL import Image
from spatial_reference import encode_restart
from jpeg_model import tables
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from block_records import BlockRecords


def verify(path):
    source = Path(path).open('rb')
    records = BlockRecords(source.read)
    frames = []
    starts = ends = 0
    while source.tell() < Path(path).stat().st_size:
        kind, frame = records.next()
        if kind == 'start': starts += 1
        if kind == 'end': ends += 1
        if kind != 'frame': continue
        assert frame.status == 0
        quality = (85, 60, 75, 85, 60, 75)[len(frames)]
        y, x = np.indices((16, 128)); cy, cx = np.indices((16, 64))
        expected = encode_restart(((3*x+2*y)&255).astype(np.uint8),
                                 ((2*cx+cy+80)&255).astype(np.uint8),
                                 ((cx+3*cy+160)&255).astype(np.uint8), False, tables(quality))
        assert frame.jpeg == expected
        with Image.open(io.BytesIO(frame.jpeg)) as image: image.load()
        assert records.spatial_stats['keyframe']
        frames.append(dict(quality=quality, **records.spatial_stats))
    assert len(frames) == 6 and starts == ends == 3
    summary = dict(passed=True, frames=frames, starts=starts, ends=ends)
    Path(path).with_suffix('.summary.json').write_text(json.dumps(summary, indent=2))
    print('SPATIAL_BOARD_PASS: six exact JPEGs, quality changes and three START/END sessions')


if __name__ == '__main__': verify(sys.argv[1])

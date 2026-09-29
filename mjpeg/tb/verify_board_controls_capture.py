"""Verify complete JPEGs across mid-frame quality changes and three sessions."""
import io
import json
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'host'))
from block_records import BlockRecords

source = io.BytesIO(Path(sys.argv[1]).read_bytes())
def exact(n):
    value = source.read(n)
    if len(value) != n:
        raise EOFError('Incomplete record')
    return value

records = BlockRecords(exact)
qualities = [85, 60, 75, 85, 60, 75]
frames = []
starts = ends = 0
while source.tell() < len(source.getbuffer()):
    kind, frame = records.next()
    if kind == 'start':
        starts += 1
    elif kind == 'end':
        ends += 1
    elif kind == 'frame':
        quality = qualities[len(frames)]
        assert frame.frame_id == len(frames) and frame.status == 0
        assert frame.jpeg == (ROOT / f'data/progressive_test/48x16.q{quality}.expected.jpg').read_bytes()
        with Image.open(io.BytesIO(frame.jpeg)) as image:
            assert image.size == (48, 16)
            image.load()
        frames.append(dict(frame_id=frame.frame_id, quality=quality, bytes=frame.length))
assert len(frames) == 6 and starts == ends == 3 and not records.in_stream
preprocess_capable=any(status['preprocess_capable'] for status in records.camera_status)
if preprocess_capable:
    assert records.preprocess_status
    for status in records.preprocess_status:
        assert status['mode_requested']==3 and status['mode']==1
        assert status['binary_threshold']==status['binary_threshold_requested']==128
        assert status['edge_threshold']==status['edge_threshold_requested']==32
        assert status['frames_started']==0x12345678
else:
    assert not records.preprocess_status
report = dict(frames=frames, starts=starts, ends=ends, golden_byte_matches=6,
              independent_decodes=6, failed_frames=0,preprocess_status_records=len(records.preprocess_status),
              preprocess_capable=preprocess_capable)
Path(sys.argv[1]).with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
print('BOARD_CONTROLS_REFERENCE_PASS: six golden JPEGs, Q85/60/75/85/60/75, three clean START/END sessions')

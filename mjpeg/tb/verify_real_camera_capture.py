"""Independent strict MBLK replay, golden JPEG and intentional abort check."""
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from block_records import BlockRecords
from camera_receiver import CameraFrames, summarize

capture = Path(sys.argv[1])
fixture = Path(sys.argv[2]).read_bytes()
source = io.BytesIO(capture.read_bytes())
def exact(n):
    value = source.read(n)
    if len(value) != n:
        raise EOFError('Partial capture')
    return value
records = BlockRecords(exact)
decoder = CameraFrames(48, 16, first_id=0)
frames = []
started = ended = 0
while True:
    kind, value = records.next()
    if kind == 'start':
        started += 1
    elif kind == 'frame':
        assert value.frame_id == len(frames)
        frames.append(value)
        if value.frame_id == 2:
            assert value.status & 1 and value.jpeg is None
            # CameraFrames checks contiguous IDs; advance over intentional fault.
            decoder.next_id = 3
        else:
            assert value.status == 0 and value.jpeg == fixture, f'Golden JPEG mismatch, frame={value.frame_id}'
            decoder.accept(value)
    elif kind == 'end':
        ended += 1
        break
assert started == ended == 1 and len(frames) == 4
assert len(decoder.frames) == 3
report = summarize(decoder.frames, records)
report['intentional_aborts'] = 1
report['golden_jpeg_bytes'] = len(fixture)
report['golden_byte_matches'] = 3
(capture.parent / 'real_camera_evidence.json').write_text(json.dumps(report, indent=2) + '\n')
print('REAL_CAMERA_REFERENCE_PASS: 3 golden JPEG byte matches and independent Pillow decodes; intentional abort and STOP framing passed')

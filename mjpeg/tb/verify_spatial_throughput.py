import json
import sys
from pathlib import Path
import numpy as np
from spatial_reference import encode_restart
from jpeg_model import tables
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_jpeg import SpatialDecoder

root = Path(sys.argv[1])
y, x = np.indices((1080, 1920)); cy, cx = np.indices((1080, 960))
expected = encode_restart(((3*x+2*y)&255).astype(np.uint8),
                         ((2*cx+cy+80)&255).astype(np.uint8),
                         ((cx+3*cy+160)&255).astype(np.uint8), False, tables(85))
decoder = SpatialDecoder()
timings = json.loads((root / 'core_timings.json').read_text())
for i, timing in enumerate(timings):
    packet = (root / f'core_fhd_{i}.jpg').read_bytes()
    assert decoder.decode(packet, i) == expected
    timing.update(spatial=decoder.last_stats, fps=100000000/timing['total_ticks'])
    assert timing['total_ticks'] < 3333333, 'Cannot sustain 1080p30 even with an ideal source'
(root / 'spatial_throughput.json').write_text(json.dumps(dict(passed=True, frames=timings), indent=2))
print(json.dumps(dict(passed=True, frames=timings)))

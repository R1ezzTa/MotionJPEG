import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_jpeg import SpatialDecoder

parser=argparse.ArgumentParser();parser.add_argument('directory',type=Path);args=parser.parse_args()
trace=json.loads((args.directory/'threshold_expected.json').read_text());decoder=SpatialDecoder()
for row in trace:
    i=row['frame_id'];actual=(args.directory/f'threshold_{i}.spj').read_bytes()
    expected=(args.directory/f'expected_threshold_{i}.spj').read_bytes()
    assert actual==expected, f'Frame{i} emitted-reference coefficient decision differs'
    decoder.decode(actual,i)
    assert decoder.last_stats['threshold']==row['threshold']
print(f'THRESHOLD_REFERENCE_PASS: {len(trace)} SPJ2 packets byte-exact to independent coefficient comparator')

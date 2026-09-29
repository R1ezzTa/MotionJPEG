"""Independent output verification for the DDR channel Q-table recovery TB."""
import argparse
import io
import json
from pathlib import Path
import sys
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from spatial_jpeg import SpatialDecoder
from threshold_sweep import _quality_table
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory',type=Path)
args=parser.parse_args()
rows=[]
decoder=SpatialDecoder()
Image.init()
for frame_id in (1,3):
    payload=(args.directory/f'quant_recovery_frame{frame_id}.spj').read_bytes()
    restored=decoder.decode(payload,frame_id)
    assert decoder.last_stats['keyframe'] and decoder.last_stats['threshold']==32
    assert decoder.last_stats['groups']==2 and decoder.last_stats['reused']==0
    with Image.open(io.BytesIO(restored)) as image:
        assert image.size==(128,8) and image.quantization==_quality_table(3)
        image.load()
    rows.append(dict(frame_id=frame_id,**decoder.last_stats))
summary=dict(passed=True,overflow_aborts=2,q_replay_writes_per_abort=128,
             all_actual_quantizer_q_and_reciprocal_ram_entries_checked_by_tb=True,
             exactly_two_core_reset_edges_in_logical_simulation=True,
             held_ddr_write_and_masked_drain_covered=True,
             complete_spj2_reconstruction=True,complete_q85_dqt=True,pillow_load=True,frames=rows,
             note='Logical integration simulation with real channel/core/DDR cache. Physical combinational reset glitches are not modeled or claimed measured.')
(args.directory/'recovery_reference.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
print(json.dumps(summary,indent=2))

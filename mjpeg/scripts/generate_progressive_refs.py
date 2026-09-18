"""Generate host-only independent JPEG references; no full-frame FPGA ROM."""
import hashlib,json,sys,time
from pathlib import Path
import numpy as np
from PIL import Image
import io
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'xilinx_mjpeg/scripts'))
from jpeg_model import encode,tables

def main():
    dest=ROOT/'data/progressive_test';dest.mkdir(exist_ok=True)
    qs=tables(85)
    loaded=[int(line,16)&255 for line in (ROOT/'data/board_test/quant.mem').read_text().splitlines()[:128]]
    assert qs==loaded,'Large-frame tests must use the existing quality-85 table'
    manifest=[]
    for w,h in [(48,16),(64,24),(96,32),(640,480),(1280,720),(1920,1080)]:
        started=time.monotonic();y,x=np.indices((h,w))
        luma=((3*x+2*y)&255).astype(np.uint8)
        cy,cx=np.indices((h,w//2))
        cb=((2*cx+cy+80)&255).astype(np.uint8)
        cr=((cx+3*cy+160)&255).astype(np.uint8)
        jpg=bytes(encode(luma,cb,cr,False,qs))
        with Image.open(io.BytesIO(jpg)) as decoded:
            assert decoded.size==(w,h);decoded.load()
        if (w,h)==(1920,1080):
            assert jpg==(ROOT.parent/'xilinx_mjpeg/data/fhd/model.jpg').read_bytes()
        (dest/f'{w}x{h}.expected.jpg').write_bytes(jpg)
        manifest.append({'width':w,'height':h,'gray':False,'quality':85,'bytes':len(jpg),'sha256':hashlib.sha256(jpg).hexdigest()})
        print(f'REFERENCE {w}x{h}: {len(jpg)} bytes, {time.monotonic()-started:.2f}s',flush=True)
    (dest/'manifest.json').write_text(json.dumps(manifest,indent=2))

if __name__=='__main__': main()

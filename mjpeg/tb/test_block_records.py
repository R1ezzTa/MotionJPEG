"""Malformed blocks and independent replay of RTL's stalled endpoint capture."""
import io,struct,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from block_records import BlockRecords

def block(kind,body=b'',flags=0): return struct.pack('<4sBBH',b'MBLK',kind,flags,len(body))+body
def reader(data):
    source=io.BytesIO(data)
    def exact(n):
        result=source.read(n)
        if len(result)!=n: raise EOFError('Partial block')
        return result
    return BlockRecords(exact)

class BlockTests(unittest.TestCase):
    def test_rejects_truncation_and_wrong_lengths(self):
        with self.assertRaises(EOFError): reader(block(4,bytes(28))[:-1]).next()
        with self.assertRaisesRegex(ValueError,'control'): reader(block(2,bytes(16))).next()
        with self.assertRaisesRegex(ValueError,'header'): reader(b'NOPE'+bytes(4)).next()

    def test_rejects_counter_overlap_and_frame_order(self):
        with self.assertRaisesRegex(ValueError,'accounting'):
            reader(block(4,struct.pack('<7I',1,100,10,40,30,30,0))).next()
        records=reader(block(6)+block(0,struct.pack('<I',0)+b'\xff\xd8\xff\xd9',2))
        records.next()
        with self.assertRaisesRegex(ValueError,'order'): records.next()

    def test_rejects_incomplete_frame_at_end(self):
        records=reader(block(6)+block(0,struct.pack('<I',0)+b'\xff\xd8',1)+block(5))
        records.next();records.next()
        with self.assertRaisesRegex(ValueError,'incomplete'): records.next()

def verify_rtl_capture(path):
    records=reader(path.read_bytes());frames=[]
    while True:
        kind,value=records.next()
        if kind=='frame': frames.append(value)
        if kind=='end': break
    assert len(frames)==3 and [f.frame_id for f in frames]==[0,1,2]
    for frame,length in zip(frames[:2],[1031,2048]):
        expected=bytearray((i*13+7)&255 for i in range(length));expected[:2]=b'\xff\xd8';expected[-2:]=b'\xff\xd9'
        assert frame.jpeg==expected and frame.length==length and frame.status==0
    assert frames[2].length==0 and frames[2].status==1 and frames[2].jpeg is None
    assert [r['window'] for r in records.rates]==[1,2,3,4]
    assert len(records.links)==1 and records.links[0]['writes']==10
    assert records.payload_blocks==5 and records.payload_bytes==3079
    print('RTL_BLOCK_CAPTURE_REFERENCE_PASS: exact byte patterns, frame descriptors, partial/full tails, abort and counters')

if __name__=='__main__':
    if len(sys.argv)==3 and sys.argv[1]=='--rtl-capture': verify_rtl_capture(Path(sys.argv[2]))
    else: unittest.main()

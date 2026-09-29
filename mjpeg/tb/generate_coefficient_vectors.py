import sys, random
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from spatial_reference import HUFF,BitWriter,symbols
import argparse
parser=argparse.ArgumentParser(description='Generate independent JPEG entropy and sparse coefficient fixtures.')
parser.add_argument('output',type=Path)
root=parser.parse_args().output;root.mkdir(parents=True,exist_ok=True)
r=random.Random(981237)
allbytes=[];allidx=[];allvals=[];meta=[];samples=[];padded=None
for case in range(32):
    gray=case%3==0
    writer=BitWriter();previous=[0]*3;expected=[]
    for b in range(4 if gray else 16):
        comp=0 if gray or b%4<2 else b%4-1
        dc=r.randint(-900,900) if case>0 else 0
        co=[dc]+[0]*63
        for k in range(1,64):
            if case>0 and r.random() < ([0.01,0.15,0.4,0.9][case%4]):
                co[k]=r.choice((-1,1))*r.choice((1,2,3,7,15,31,63,127,255,511,1023))
        for d,s,a,n in symbols(co,previous[comp]):
            code,ln=HUFF[(0 if comp==0 else 2)+(0 if d else 1)][s]
            writer.put(code,ln);writer.put(a,n)
        previous[comp]=dc
        expected.extend((b*64+k,x) for k,x in enumerate(co) if k==0 or x!=0)
    padding=(8-writer.n)%8
    data=bytes(writer.finish());samples.append((gray,data))
    if padding and padded is None: padded=(gray,data)
    meta.extend((gray,len(allbytes),len(data),len(allidx),len(expected)))
    allbytes.extend(data);allidx.extend(i for i,x in expected);allvals.extend(v&65535 for i,v in expected)
bad=[]
# Truncated entropy; extra entropy after the last block; a zero padding bit;
# invalid stuffing; nonexistent Huffman all-ones code; AC run beyond coefficient63.
bad.append((samples[3][0],samples[3][1][:-1]))
bad.append((samples[0][0],samples[0][1]+b'\x00'))
gray,data=padded
changed=bytearray(data);changed[-2 if data[-2:]==b'\xff\x00' else -1]^=1
bad.append((gray,bytes(changed)))
bad.append((True,b'\xff\x01'))
bad.append((True,b'\xff\x00\xff\x00'))
w=BitWriter();c,n=HUFF[0][0];w.put(c,n)
c,n=HUFF[1][0xf0]
for _ in range(4):w.put(c,n)
bad.append((True,bytes(w.finish())))
bad.append((samples[0][0],samples[0][1]+b'\x00'*16))
for gray,data in bad:
    meta.extend((gray,len(allbytes),len(data),0,0xffffffff));allbytes.extend(data)
for name,values,w in [('data' ,allbytes,2),('index',allidx,3),('value',allvals,4),('meta',meta,8)]:
    (root/(name+'.hex')).write_text('\n'.join(f'{v:0{w}x}' for v in values)+'\n')
print('Cases',39,'entropybytes',len(allbytes),'coefficients',len(allidx))

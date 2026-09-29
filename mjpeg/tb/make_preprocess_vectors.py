"""Independent whole-frame reference; reflected boundaries and exact YUV words."""
import argparse
import json
import random
from pathlib import Path

def preprocess(image, mode, binary, edge):
    h,w=len(image),len(image[0])
    reflect=lambda x,n: -x if x<0 else 2*n-2-x if x>=n else x
    result=[]
    for y in range(h):
        for x in range(w):
            p=image[y][x]
            if mode==0:
                result.append(p)
                continue
            value=p&255
            if mode==2:
                value=255 if value>=binary else 0
            elif mode==3:
                a=[[image[reflect(y+dy,h)][reflect(x+dx,w)]&255 for dx in (-1,0,1)] for dy in (-1,0,1)]
                gx=a[0][2]-a[0][0]+2*(a[1][2]-a[1][0])+a[2][2]-a[2][0]
                gy=a[2][0]-a[0][0]+2*(a[2][1]-a[0][1])+a[2][2]-a[0][2]
                strength=min(255,(abs(gx)+abs(gy)+2)//4)
                value=strength if strength>=edge else 0
            result.append(0x8000|value)
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--width',type=int,default=16)
    p.add_argument('--height',type=int,default=8)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    assert a.width>=4 and a.width%2==0 and a.height>=2
    rng=random.Random(2809)
    configs=[(0,128,32),(1,128,32),(2,128,32),(3,128,32),(2,0,255),
             (2,255,0),(3,128,0),(3,128,255),(0,99,7),(3,128,32),(3,128,64),(3,128,1)]
    source=[];golden=[]
    for f,(mode,binary,edge) in enumerate(configs):
        image=[]
        for y in range(a.height):
            row=[]
            for x in range(a.width):
                value=rng.randrange(256)
                if f==9: value=73
                if f==10: value=0 if x<a.width//2 else 255
                if f==11: value=0 if y<a.height//2 else 255
                row.append((rng.randrange(256)<<8)|value)
            image.append(row)
        source.extend(v for row in image for v in row)
        golden.extend(preprocess(image,mode,binary,edge))
    flat=[[0x9949]*8 for _ in range(4)]
    assert preprocess(flat,0,128,32)==[0x9949]*32
    assert preprocess(flat,1,128,32)==[0x8049]*32
    assert preprocess(flat,3,128,32)==[0x8000]*32
    assert preprocess(flat,3,128,0)==[0x8000]*32
    ramp=[[(0x99<<8)|10*x for x in range(8)] for _ in range(4)]
    assert preprocess(ramp,3,128,19)[2*8+3]==0x8014
    assert preprocess(ramp,3,128,21)[2*8+3]==0x8000
    for name,words,width in [('source',source,4),('golden',golden,4),
                             ('config',[(m<<16)|(e<<8)|b for m,b,e in configs],5)]:
        (a.output/(name+'.mem')).write_text(''.join(f'{v:0{width}x}\n' for v in words))
    (a.output/'reference_summary.json').write_text(json.dumps(dict(width=a.width,height=a.height,
        frames=len(configs),configs=configs,reference='whole-frame integer Sobel, independent spatial access'),indent=2))

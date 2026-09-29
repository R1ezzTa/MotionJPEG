from pathlib import Path
import argparse
from denoise_yuv_reference import denoise_yuv
parser=argparse.ArgumentParser()
parser.add_argument('--width',type=int,default=16)
parser.add_argument('--height',type=int,default=8)
parser.add_argument('--frames',type=int,default=3)
parser.add_argument('--constant',action='store_true')
parser.add_argument('--denoise-strength',type=int,default=0)
parser.add_argument('--pattern',choices=('BGGR','GRBG','GBRG','RGGB'),default='BGGR')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();W,H=args.width,args.height;root=args.output
pattern={'BGGR':(('B','G'),('G','R')),'GRBG':(('G','R'),('B','G')),
         'GBRG':(('G','B'),('R','G')),'RGGB':(('R','G'),('G','B'))}[args.pattern]
root.mkdir(parents=True,exist_ok=True)
if args.constant:
    # Reflected bilinear reconstruction of a uniform RGB field is exact.
    # This exercises every pixel, marker, line bank and border at full HD.
    with (root/'raw.mem').open('w') as src,(root/'golden.mem').open('w') as dst:
        for frame in range(args.frames):
            r,g,b=160,96,32
            yy=(77*r+150*g+29*b)//256
            cb=(32768-43*r-85*g+128*b)//256
            cr=(32768+128*r-107*g-21*b)//256
            for y in range(H):
                colors={'R':r,'G':g,'B':b}
                src.write((f'{colors[pattern[y%2][0]]:02x}\n{colors[pattern[y%2][1]]:02x}\n'*(W//2)))
                dst.write((f'{yy|cb<<8:04x}\n{yy|cr<<8:04x}\n'*(W//2)))
    raise SystemExit(0)
raw=[];expected=[]
for frame in range(args.frames):
    image=[[(x*17+y*29+x*y*3+frame*71+(x*x+13*y*y)*frame)%256 for x in range(W)] for y in range(H)]
    rgb=[]
    def at(x,y):
        x=abs(x) if x<0 else (2*W-2-x if x>=W else x)
        y=abs(y) if y<0 else (2*H-2-y if y>=H else y)
        return image[y][x]
    for y in range(H):
        row=[]
        for x in range(W):
            c=at(x,y);cross=sum(at(x+dx,y+dy) for dx,dy in [(0,-1),(-1,0),(1,0),(0,1)])//4
            diag=sum(at(x+dx,y+dy) for dx,dy in [(-1,-1),(1,-1),(-1,1),(1,1)])//4
            hor=(at(x-1,y)+at(x+1,y))//2;ver=(at(x,y-1)+at(x,y+1))//2
            color=pattern[y%2][x%2]
            if color=='R': r,g,b=c,cross,diag
            elif color=='B': r,g,b=diag,cross,c
            elif pattern[y%2][(x+1)%2]=='R': r,g,b=hor,c,ver
            else: r,g,b=ver,c,hor
            row.append((r,g,b));raw.append(c)
        rgb.append(row)
    yuv=[]
    for row in rgb:
        yuv_row=[]
        for x,(r,g,b) in enumerate(row):
            yy=(77*r+150*g+29*b)//256
            cb=max(0,min(255,(32768-43*r-85*g+128*b)//256))
            cr=max(0,min(255,(32768+128*r-107*g-21*b)//256))
            yuv_row.append((yy,cb,cr))
        yuv.append(yuv_row)
    yuv=denoise_yuv(yuv,args.denoise_strength)
    for row in yuv:
        for x,(yy,cb,cr) in enumerate(row):
            expected.append(yy|((cr if x%2 else cb)<<8))
(root/'raw.mem').write_text(''.join(f'{v:02x}\n' for v in raw))
(root/'golden.mem').write_text(''.join(f'{v:04x}\n' for v in expected))

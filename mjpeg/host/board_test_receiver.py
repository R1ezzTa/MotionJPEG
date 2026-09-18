"""Verify FPGA JPEGs and report the same one-second FPS shown on the board."""
import argparse, csv, hashlib, io, json, time
from collections import deque
import struct
from pathlib import Path
from functools import lru_cache
from PIL import Image
from mjpeg_receiver import Receiver

CASES = [('gray_ramp',16,16,True), ('color_noise',32,24,False), ('color_flat',16,8,False)]

@lru_cache(maxsize=3)
def reference_bytes(root,name):
    return (root/'data'/'board_test'/f'{name}.expected.jpg').read_bytes()

def verify_frame(frame, index, root, dest, session, save=True):
    name,w,h,gray = CASES[index % 3]
    expected=reference_bytes(root,name)
    if (frame.channel,frame.width,frame.height,frame.gray,frame.status)!=(0,w,h,gray,0):
        raise ValueError(f'Bad frame metadata: {frame}')
    if frame.jpeg != expected:
        raise ValueError(f'JPEG differs from reference: {name}, frame {frame.frame_id}')
    with Image.open(io.BytesIO(frame.jpeg)) as image:
        image.load()
        if image.size != (w,h): raise ValueError('Decoder dimensions')
        if save: image.save(dest/f'session{session}_frame{frame.frame_id}_{name}.png')
    if save: (dest/f'session{session}_frame{frame.frame_id}_{name}.jpg').write_bytes(frame.jpeg)
    return {**{k:v for k,v in vars(frame).items() if k!='jpeg'}, 'case':name,
            'session':session,'sha256':hashlib.sha256(frame.jpeg).hexdigest(),
            'reference_equal':True,'decoded':True}

class BoardRecords:
    """Telemetry is independent of JPEG packet boundaries, never JPEG payload."""
    def __init__(self, read_exact):
        self.read_exact=read_exact; self.rates=[]; self.timings=[]; self.in_stream=False
        self.packet_events=deque()
        self.buffered_reader=getattr(read_exact,'__self__',None)

    def next_packet(self):
        """Read a whole bus packet, retaining telemetry interleaved between words."""
        if self.packet_events: return self.packet_events.popleft()
        kind,value=self.next()
        if kind!='word': return kind,value
        data,nbytes,last=value
        if nbytes!=4 or last or data>>16!=0x4d4a or data>>12&15!=1:
            raise ValueError('Invalid packet header')
        packet_kind=data>>10&3;count=data&31
        if packet_kind>1 or count>16 or packet_kind==1 and count:
            raise ValueError('Invalid packet kind/length')
        length=7 if packet_kind==1 else 2+(count+3)//4
        words=[value]
        if hasattr(self.buffered_reader,'rewind'):
            block=self.read_exact(5*(length-1))
            records=list(struct.iter_unpack('<IB',block))
            if all(flag&0xf0==0 and 1<=flag&7<=4 for _,flag in records):
                words.extend((word,flag&7,bool(flag&8)) for word,flag in records)
                return 'packet',words
            # Control records can occur at any word boundary in existing captures.
            self.buffered_reader.rewind(len(block))
        while len(words)<length:
            kind,value=self.next()
            if kind=='word': words.append(value)
            elif kind in ('fps','timing'): self.packet_events.append((kind,value))
            else: raise ValueError('Stream boundary inside packet')
        self.packet_events.append(('packet',words))
        return self.packet_events.popleft()

    def next(self):
        if self.in_stream:
            record=self.read_exact(5); word=record[:4]; flag=record[4]
        else:
            word=self.read_exact(4)
            if word==b'MJBT':
                self.in_stream=True
                return 'start',None
            flag=self.read_exact(1)[0]
        data=int.from_bytes(word,'little')
        if flag==0xa0:
            if word!=b'END1': raise ValueError('Bad stream end signature')
            self.in_stream=False
            return 'end',None
        if flag==0x90:
            if word!=b'TIM1': raise ValueError('Bad frame timing signature')
            values=[]
            for expected in range(0x91,0x97):
                record=self.read_exact(5)
                if record[4]!=expected: raise ValueError('Incomplete/out-of-order frame timing')
                values.append(int.from_bytes(record[:4],'little'))
            timing=dict(zip(('frame_id','feed_ticks','jpeg_ticks','total_ticks','input_wait_ticks','output_wait_ticks'),values))
            if not 0<timing['feed_ticks']<=timing['jpeg_ticks']<=timing['total_ticks']:
                raise ValueError('Invalid frame timing order')
            if timing['input_wait_ticks']>timing['feed_ticks'] or timing['output_wait_ticks']>timing['total_ticks']:
                raise ValueError('Invalid frame stall counts')
            self.timings.append(timing)
            return 'timing',timing
        if flag==0x80:
            if word!=b'FPS1': raise ValueError('Bad FPS telemetry signature')
            values=[]
            for expected in range(0x81,0x86):
                record=self.read_exact(5)
                if record[4]!=expected: raise ValueError('Incomplete/out-of-order FPS snapshot')
                values.append(int.from_bytes(record[:4],'little'))
            rate=dict(zip(('window','input_fps','compressed_fps','failed_fps','total_compressed'),values))
            if self.rates:
                previous=self.rates[-1]
                if rate['window']<=previous['window']: raise ValueError('FPS window sequence')
                if rate['total_compressed']<previous['total_compressed']: raise ValueError('FPS total regressed')
                if rate['window']==previous['window']+1 and rate['total_compressed']-previous['total_compressed']!=rate['compressed_fps']:
                    raise ValueError('FPS window count differs from cumulative total')
            self.rates.append(rate)
            print(f"FPGA window {rate['window']}: input={rate['input_fps']} compression={rate['compressed_fps']} fps, failed={rate['failed_fps']}, total={rate['total_compressed']}",flush=True)
            return 'fps',rate
        if flag&0xf0 or not 1<=flag&7<=4: raise ValueError(f'Invalid bus flags {flag:#04x}')
        return 'word',(data,flag&7,bool(flag&8))

def read_session(records, root, dest, session, expected_id):
    while True:
        kind,value=records.next()
        if kind=='fps': continue
        if kind!='start': raise ValueError('Missing MJBT preamble')
        break
    receiver=Receiver(); metadata=[]; bus_rows=[]
    for index in range(9):
        while True:
            kind,value=records.next()
            if kind=='fps': continue
            if kind!='word': raise ValueError('Unexpected stream preamble')
            data,nbytes,last=value
            bus_rows.append(f'{data:08x},{nbytes},{int(last)}\n')
            frame=receiver.word(data,nbytes,last)
            if frame is not None: break
        if frame.frame_id != expected_id+index: raise ValueError('Unexpected frame sequence')
        metadata.append(verify_frame(frame,index,root,dest,session))
    if receiver.frames or receiver.packet: raise ValueError('Partial frame remains')
    (dest/f'session{session}_bus.csv').write_text('data,bytes,last\n'+''.join(bus_rows))
    records.in_stream=False
    return metadata

def read_live(records, stream, root, dest, duration, expected_id, capture=False):
    if not capture: stream.write(b'C'); stream.flush()
    receiver=Receiver(); frames=[]; started=False; stopped=capture; idle_windows=0
    deadline=time.monotonic()+duration
    while True:
        if not capture and time.monotonic()>deadline+30: raise TimeoutError('Continuous camera did not stop and report idle')
        if not stopped and time.monotonic()>=deadline:
            stream.write(b'S'); stream.flush(); stopped=True
            print('STOP sent; waiting for complete frame and zero-FPS windows',flush=True)
        kind,value=records.next()
        if kind=='start':
            if started: raise ValueError('Unexpected second live preamble')
            started=True
        elif kind=='word':
            if not started: raise ValueError('JPEG before live preamble')
            frame=receiver.word(*value)
            if frame is not None:
                if frame.frame_id!=expected_id+len(frames): raise ValueError('Live frame sequence')
                frames.append(verify_frame(frame,len(frames),root,dest,0,save=len(frames)<3))
        else:
            if value['failed_fps']: raise ValueError('FPGA reports failed compression')
            if stopped and started and frames and value['input_fps']==value['compressed_fps']==0:
                idle_windows+=1
                if idle_windows>=2:
                    if receiver.frames or receiver.packet: raise ValueError('Partial frame after stop')
                    if not frames or value['total_compressed']!=expected_id+len(frames):
                        raise ValueError('FPGA total differs from verified live frames')
                    break
            else: idle_windows=0
    if not any(r['compressed_fps']>0 for r in records.rates): raise ValueError('No positive FPGA FPS received')
    return frames

def main():
    p=argparse.ArgumentParser(); source=p.add_mutually_exclusive_group(required=True)
    source.add_argument('--port'); source.add_argument('--capture',type=Path)
    source.add_argument('--ftdi',action='store_true');p.add_argument('--library')
    p.add_argument('--sessions',type=int,default=3); p.add_argument('--baud',type=int,default=115200)
    p.add_argument('--live',action='store_true',help='C/S continuous camera mode; verify every frame, save first three images')
    p.add_argument('--duration',type=float,default=10,help='Continuous encoding seconds before S (then wait two idle windows)')
    p.add_argument('--first-id',type=int,default=0)
    p.add_argument('--fps-expected',type=Path,help='Compare every simulated telemetry snapshot against the independent TB trace')
    p.add_argument('--output',type=Path,required=True); args=p.parse_args()
    root=Path(__file__).resolve().parents[1]; args.output.mkdir(parents=True,exist_ok=True)
    if args.live and (not (args.ftdi or args.capture) or args.duration<=0):
        p.error('--live requires --ftdi or --capture and a positive --duration')
    raw=bytearray(); all_frames=[]
    if args.capture:
        stream=io.BytesIO(args.capture.read_bytes())
        def read_exact(n):
            data=stream.read(n)
            if len(data)!=n: raise EOFError('Truncated simulation serial capture')
            raw.extend(data); return data
    else:
        if args.ftdi:
            from ftdi_fifo import FtdiFifo
            stream=FtdiFifo(library=args.library)
            print(f'FTDI DATA CHIP FTB7MA1D open, EEPROM word0={stream.eeprom_word0:#06x}',flush=True)
            (args.output/'ftdi_info.json').write_text(json.dumps(stream.eeprom_info,indent=2))
        else:
            import serial
            stream=serial.Serial(args.port,args.baud,timeout=0.2,rtscts=False,dsrdtr=False)
        stream.reset_input_buffer()
        def read_exact(n):
            data=bytearray(); deadline=time.monotonic()+30
            while len(data)<n and time.monotonic()<deadline: data.extend(stream.read(n-len(data)))
            if len(data)!=n: raise TimeoutError(f'Board read timed out: {len(data)}/{n} bytes')
            raw.extend(data); return bytes(data)
    records=BoardRecords(read_exact)
    try:
        if args.live:
            all_frames=read_live(records,stream,root,args.output,args.duration,args.first_id,capture=bool(args.capture))
            if args.capture and stream.tell()!=len(stream.getbuffer()): raise ValueError('Trailing live capture data')
        else:
            for session in range(args.sessions):
                if not args.capture:
                    time.sleep(0.1); stream.write(b'G'); stream.flush()
                frames=read_session(records,root,args.output,session,args.first_id+session*9)
                all_frames.extend(frames)
                print(f'SESSION {session} PASS: 9 FPGA JPEGs match references and decode',flush=True)
            if args.capture:
                while stream.tell()<len(stream.getbuffer()):
                    if records.next()[0]!='fps': raise ValueError('Trailing non-telemetry simulation data')
        if args.fps_expected:
            with args.fps_expected.open() as trace:
                expected=[{k:int(v) for k,v in row.items()} for row in csv.DictReader(trace)]
            if records.rates!=expected: raise ValueError('USB FPS snapshots differ from independent simulation events')
    finally:
        if args.live and not args.capture:
            stream.write(b'S'); stream.flush()
        stream.close(); (args.output/('usb_capture.bin' if args.ftdi else 'uart_capture.bin')).write_bytes(raw)
    (args.output/'frames.json').write_text(json.dumps(all_frames,indent=2))
    (args.output/'fps.json').write_text(json.dumps(records.rates,indent=2))
    (args.output/'VERIFY_PASS.txt').write_text(f'{len(all_frames)} JPEG frames: byte-for-byte reference match, metadata/sequence valid, Pillow decode passed.\n')
    print(f'VERIFIED {len(all_frames)} frames',flush=True)

if __name__=='__main__': main()

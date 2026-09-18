"""Run graduated colour-ramp tests through 1920x1080 on the actual FPGA."""
import argparse,hashlib,io,json,statistics,time
from pathlib import Path
from PIL import Image
from board_test_receiver import BoardRecords
from mjpeg_receiver import Receiver

ROOT=Path(__file__).resolve().parents[1]
CLOCK_HZ=50000000

class CaptureReader:
    def __init__(self,source,capture=None,replay=False):
        self.source=source;self.capture=capture;self.replay=replay
        self.block=b'';self.pos=0;self.offset=0

    def exact(self,n):
        if self.pos+n>len(self.block):
            pending=self.block[self.pos:];deadline=time.monotonic()+30
            while len(pending)<n:
                data=self.source.read(65536) if self.replay else self.source.read_chunk()
                if not data:
                    if self.replay: raise EOFError('Capture ended at record boundary' if not pending else 'Partial record')
                    if time.monotonic()>deadline: raise TimeoutError('USB data timeout')
                    continue
                if self.capture: self.capture.write(data)
                pending+=data
            self.block=pending;self.pos=0
        result=self.block[self.pos:self.pos+n];self.pos+=n;self.offset+=n
        return result

def phase(records,reader,stream,w,h,command,first_id,dest,seconds,min_frames,replay=False):
    expected=(ROOT/'data/progressive_test'/f'{w}x{h}.expected.jpg').read_bytes()
    receiver=Receiver();frames=[];timings=[];started=False;ended=False;stopped=False;idle=0;first_jpeg=None
    start_offset=reader.offset;rate_start=len(records.rates)
    began=time.monotonic()
    if not replay: stream.write(command);stream.flush()
    while True:
        if not replay and time.monotonic()-began>max(180,seconds*4):
            raise TimeoutError(f'{w}x{h} phase watchdog')
        if not replay and not stopped and len(frames)>=min_frames and time.monotonic()-began>=seconds:
            stream.write(b'S');stream.flush();stopped=True
            print(f'STOP {w}x{h}; drain final frame and wait END1',flush=True)
        kind,value=records.next()
        if kind=='start':
            if started: raise ValueError('Unexpected phase preamble')
            started=True
        elif kind=='word':
            if not started or ended: raise ValueError('JPEG outside active phase')
            frame=receiver.word(*value)
            if frame is None: continue
            if (frame.frame_id,frame.width,frame.height,frame.gray,frame.status)!=(first_id+len(frames),w,h,False,0):
                raise ValueError(f'Frame metadata/sequence/status {frame.frame_id}')
            if frame.jpeg!=expected: raise ValueError(f'JPEG reference mismatch {w}x{h} frame {frame.frame_id}')
            with Image.open(io.BytesIO(frame.jpeg)) as image:
                if image.size!=(w,h): raise ValueError('Decoder dimensions')
                image.load()
            frames.append({**{k:v for k,v in vars(frame).items() if k!='jpeg'},'decoded':True,'reference_equal':True,'sha256':hashlib.sha256(frame.jpeg).hexdigest()})
            if first_jpeg is None: first_jpeg=frame.jpeg
            print(f'FRAME {w}x{h} id={frame.frame_id} {frame.length} JPEG bytes PASS',flush=True)
        elif kind=='timing':
            if not started or ended: raise ValueError('Timing outside active phase')
            timings.append(value)
        elif kind=='end':
            if not started or ended or receiver.frames or receiver.packet: raise ValueError('END before complete frames')
            ended=True
            if [t['frame_id'] for t in timings]!=[f['frame_id'] for f in frames]: raise ValueError('Missing frame timings')
            for timing in timings:
                if timing['feed_ticks']-timing['input_wait_ticks']!=2*(w*h-1):
                    raise ValueError('Input timing does not account for the full frame pixel count')
        else:
            if value['failed_fps']: raise ValueError('FPGA reports failed frame')
            if ended and value['compressed_fps']==value['input_fps']==0:
                idle+=1
                if idle>=2:
                    if value['total_compressed']!=first_id+len(frames): raise ValueError('FPGA total differs from received frames')
                    break
            elif ended: idle=0
    rates=records.rates[rate_start:]
    if not frames or not replay and len(frames)<min_frames: raise ValueError('Insufficient frames')
    if sum(r['compressed_fps'] for r in rates)!=len(frames): raise ValueError('Window frame sum mismatch')
    if sum(r['input_fps'] for r in rates)!=len(frames): raise ValueError('Window input sum mismatch')
    for left,right in zip(frames,frames[1:]):
        if right['timestamp']<=left['timestamp']: raise ValueError('Timestamp sequence')
    fps=(len(frames)-1)*CLOCK_HZ/(frames[-1]['timestamp']-frames[0]['timestamp']) if len(frames)>1 else None
    phase_dir=dest/f'{w}x{h}';phase_dir.mkdir(exist_ok=True)
    (phase_dir/'first_frame.jpg').write_bytes(first_jpeg)
    with Image.open(io.BytesIO(first_jpeg)) as image: image.save(phase_dir/'first_frame.png')
    (phase_dir/'frames.json').write_text(json.dumps(frames,indent=2))
    (phase_dir/'timings.json').write_text(json.dumps(timings,indent=2))
    (phase_dir/'fps.json').write_text(json.dumps(rates,indent=2))
    result={'width':w,'height':h,'pixels':w*h,'quality':85,'frames':len(frames),'first_frame_id':first_id,
            'last_frame_id':frames[-1]['frame_id'],'jpeg_bytes_per_frame':len(expected),'jpeg_sha256':hashlib.sha256(expected).hexdigest(),
            'start_interval_fps':fps,'pixel_rate_mpix_s':w*h*fps/1e6 if fps else None,
            'mean_feed_ms':statistics.mean(t['feed_ticks'] for t in timings)*1000/CLOCK_HZ,
            'mean_jpeg_end_ms':statistics.mean(t['jpeg_ticks'] for t in timings)*1000/CLOCK_HZ,
            'mean_descriptor_end_ms':statistics.mean(t['total_ticks'] for t in timings)*1000/CLOCK_HZ,
            'input_wait_fraction':sum(t['input_wait_ticks'] for t in timings)/sum(t['feed_ticks'] for t in timings),
            'output_wait_fraction':sum(t['output_wait_ticks'] for t in timings)/sum(t['total_ticks'] for t in timings),
            'window_fps_values':sorted(set(r['compressed_fps'] for r in rates)),
            'idle_windows_verified':2,'wire_start_offset':start_offset,'wire_end_offset':reader.offset,
            'wire_expansion':(reader.offset-start_offset)/sum(f['length'] for f in frames),
            'passed':True,'host_elapsed_seconds':time.monotonic()-began}
    (phase_dir/'result.json').write_text(json.dumps(result,indent=2))
    print(f"PHASE PASS {w}x{h}: {len(frames)} frames; {fps:.3f} fps" if fps else f'PHASE PASS {w}x{h}',flush=True)
    return result

def main():
    p=argparse.ArgumentParser();source=p.add_mutually_exclusive_group(required=True)
    source.add_argument('--ftdi',action='store_true');source.add_argument('--capture',type=Path)
    p.add_argument('--library');p.add_argument('--simulation',action='store_true')
    p.add_argument('--seconds',type=float,default=30);p.add_argument('--min-frames',type=int,default=6)
    p.add_argument('--first-id',type=int,default=0);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--timing-expected',type=Path);args=p.parse_args()
    if args.seconds<=0 or args.min_frames<2: p.error('positive seconds and at least two frames required')
    if args.simulation and not args.capture: p.error('--simulation is only for replaying scaled TB frames')
    args.output.mkdir(parents=True,exist_ok=True)
    if args.capture: stream=args.capture.open('rb');raw=None
    else:
        from ftdi_fifo import FtdiFifo
        stream=FtdiFifo(library=args.library);raw=(args.output/'usb_capture.bin').open('wb')
        (args.output/'ftdi_info.json').write_text(json.dumps(stream.eeprom_info,indent=2))
    reader=CaptureReader(stream,raw,replay=bool(args.capture));records=BoardRecords(reader.exact)
    plan=[(48,16,b'V'),(64,24,b'H'),(96,32,b'F')] if args.simulation else [(640,480,b'V'),(1280,720,b'H'),(1920,1080,b'F')]
    results=[];first_id=args.first_id
    try:
        for w,h,command in plan:
            result=phase(records,reader,stream,w,h,command,first_id,args.output,args.seconds,args.min_frames,replay=bool(args.capture))
            results.append(result);first_id+=result['frames']
            (args.output/'results.json').write_text(json.dumps(results,indent=2))
        if args.capture:
            while reader.pos<len(reader.block) or stream.peek(1):
                kind,value=records.next()
                if kind!='fps': raise ValueError('Trailing non-telemetry records')
        if args.timing_expected:
            expected=json.loads(args.timing_expected.read_text())
            if records.timings!=expected: raise ValueError('Frame timings differ from independent TB clock counts')
    finally:
        if not args.capture:
            stream.write(b'S');stream.flush()
        stream.close()
        if raw: raw.close()
    (args.output/'VERIFY_PASS.txt').write_text(f'{sum(r["frames"] for r in results)} frames across three graduated resolutions; reference JPEG equality, independent decoding, frame sequence, frame timings and FPGA FPS/idle counts passed.\n')
    print('PROGRESSIVE_TEST_PASS',flush=True)

if __name__=='__main__':main()

"""Run graduated colour-ramp tests through 1920x1080 on the actual FPGA."""
import argparse,csv,hashlib,io,json,statistics,time
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

    def rewind(self,n):
        if not 0<=n<=self.pos: raise ValueError('Invalid buffered capture rewind')
        self.pos-=n;self.offset-=n

def phase(records,reader,stream,w,h,command,first_id,dest,seconds,min_frames,replay=False,packet_batches=True,receive_only=False,pixel_cycles=None,link_clock_hz=CLOCK_HZ,core_clock_hz=CLOCK_HZ,scaled_windows=False):
    expected=(ROOT/'data/progressive_test'/f'{w}x{h}.expected.jpg').read_bytes()
    receiver=Receiver();frames=[];timings=[];started=False;ended=False;stopped=False;idle=0;first_jpeg=None
    start_offset=reader.offset;rate_start=len(records.rates)
    link_start=len(getattr(records,'links',[]))
    began=time.monotonic()
    began_cpu=time.process_time()
    measured_pixel_cycles=pixel_cycles
    if not replay: stream.write(command);stream.flush()
    while True:
        if not replay and time.monotonic()-began>max(180,seconds*4):
            raise TimeoutError(f'{w}x{h} phase watchdog')
        if not replay and not stopped and len(frames)>=min_frames and time.monotonic()-began>=seconds:
            stream.write(b'S');stream.flush();stopped=True
            print(f'STOP {w}x{h}; drain final frame and wait END1',flush=True)
        kind,value=records.next_packet() if packet_batches else records.next()
        if kind=='start':
            if started: raise ValueError('Unexpected phase preamble')
            started=True
        elif kind in ('word','packet','frame'):
            if not started or ended: raise ValueError('JPEG outside active phase')
            frame=value if kind=='frame' else receiver.packet_words(value) if kind=='packet' else receiver.word(*value)
            if frame is None: continue
            if (frame.frame_id,frame.width,frame.height,frame.gray,frame.status)!=(first_id+len(frames),w,h,False,0):
                raise ValueError(f'Frame metadata/sequence/status {frame.frame_id}')
            if not receive_only:
                if frame.jpeg!=expected: raise ValueError(f'JPEG reference mismatch {w}x{h} frame {frame.frame_id}')
                with Image.open(io.BytesIO(frame.jpeg)) as image:
                    if image.size!=(w,h): raise ValueError('Decoder dimensions')
                    image.load()
            frames.append({**{k:v for k,v in vars(frame).items() if k!='jpeg'},'decoded':not receive_only,'reference_equal':not receive_only,'sha256':hashlib.sha256(frame.jpeg).hexdigest() if not receive_only else None})
            if first_jpeg is None: first_jpeg=frame.jpeg
            if not receive_only or len(frames)%100==0:
                print(f'FRAME {w}x{h} id={frame.frame_id} {frame.length} JPEG bytes '+('CAPTURED' if receive_only else 'PASS'),flush=True)
        elif kind=='timing':
            if not started or ended: raise ValueError('Timing outside active phase')
            timings.append(value)
        elif kind=='end':
            if not started or ended or receiver.frames or receiver.packet: raise ValueError('END before complete frames')
            ended=True
            if [t['frame_id'] for t in timings]!=[f['frame_id'] for f in frames]: raise ValueError('Missing frame timings')
            for timing in timings:
                active_ticks=timing['feed_ticks']-timing['input_wait_ticks']
                if measured_pixel_cycles is None:
                    measured_pixel_cycles,remainder=divmod(active_ticks,w*h-1)
                    if remainder or measured_pixel_cycles not in (1,2):
                        raise ValueError('Unknown pixel source cadence')
                if active_ticks!=measured_pixel_cycles*(w*h-1):
                    raise ValueError('Input timing does not account for the full frame pixel count')
        elif kind in ('chunk','link'): continue
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
    fps=(len(frames)-1)*core_clock_hz/(frames[-1]['timestamp']-frames[0]['timestamp']) if len(frames)>1 else None
    # Independent one-second FPGA frame counts expose the wrong timestamp
    # clock setting. Scaled TB windows deliberately are not real seconds.
    active_windows=[r['window'] for r in rates if r['input_fps'] or r['compressed_fps']]
    steady_rates=[r for r in rates if min(active_windows)<r['window']<max(active_windows)]
    if not scaled_windows and fps and len(steady_rates)>=3:
        counted_fps=statistics.mean(r['compressed_fps'] for r in steady_rates)
        if abs(fps-counted_fps)>max(2.0,counted_fps*0.05):
            raise ValueError(f'Timestamp FPS {fps:.3f} differs from FPGA windows {counted_fps:.3f}; check --core-clock-hz')
    phase_dir=dest/f'{w}x{h}';phase_dir.mkdir(exist_ok=True)
    if not receive_only:
        (phase_dir/'first_frame.jpg').write_bytes(first_jpeg)
        with Image.open(io.BytesIO(first_jpeg)) as image: image.save(phase_dir/'first_frame.png')
    (phase_dir/'frames.json').write_text(json.dumps(frames,indent=2))
    (phase_dir/'timings.json').write_text(json.dumps(timings,indent=2))
    (phase_dir/'fps.json').write_text(json.dumps(rates,indent=2))
    result={'width':w,'height':h,'pixels':w*h,'quality':85,'frames':len(frames),'first_frame_id':first_id,
            'last_frame_id':frames[-1]['frame_id'],'jpeg_bytes_per_frame':len(expected),'jpeg_sha256':hashlib.sha256(expected).hexdigest(),
            'start_interval_fps':fps,'pixel_rate_mpix_s':w*h*fps/1e6 if fps else None,
            'mean_feed_ms':statistics.mean(t['feed_ticks'] for t in timings)*1000/core_clock_hz,
            'mean_jpeg_end_ms':statistics.mean(t['jpeg_ticks'] for t in timings)*1000/core_clock_hz,
            'mean_descriptor_end_ms':statistics.mean(t['total_ticks'] for t in timings)*1000/core_clock_hz,
            'input_wait_fraction':sum(t['input_wait_ticks'] for t in timings)/sum(t['feed_ticks'] for t in timings),
            'output_wait_fraction':sum(t['output_wait_ticks'] for t in timings)/sum(t['total_ticks'] for t in timings),
            'window_fps_values':sorted(set(r['compressed_fps'] for r in rates)),
            'idle_windows_verified':2,'wire_start_offset':start_offset,'wire_end_offset':reader.offset,
            'wire_expansion':(reader.offset-start_offset)/sum(f['length'] for f in frames),
            'host_packet_batches':packet_batches,'receive_only':receive_only,'reference_verified':not receive_only,
            'pixel_cycles':measured_pixel_cycles,
            'link_clock_hz':link_clock_hz,
            'core_clock_hz':core_clock_hz,
            'passed':not receive_only,'host_elapsed_seconds':time.monotonic()-began}
    result['host_cpu_seconds']=time.process_time()-began_cpu
    result['host_cpu_fraction']=result['host_cpu_seconds']/result['host_elapsed_seconds']
    links=getattr(records,'links',[])[link_start:]
    if links:
        (phase_dir/'link_windows.json').write_text(json.dumps(links,indent=2))
        active=[r['window'] for r in rates if r['input_fps'] or r['compressed_fps']]
        steady=[s for s in links if min(active)<s['window']<max(active)]
        if steady:
            totals={k:sum(s[k] for s in steady) for k in steady[0] if k!='window'}
            result['steady_link_windows']=len(steady)
            result['link_totals']=totals
            result['link_cycle_fractions']={k:v/totals['cycles'] for k,v in totals.items() if k!='cycles'}
            result['steady_wire_mbytes_s']=totals['writes']*link_clock_hz/totals['cycles']/1e6
    (phase_dir/'result.json').write_text(json.dumps(result,indent=2))
    label='CAPTURE' if receive_only else 'PASS'
    print(f"PHASE {label} {w}x{h}: {len(frames)} frames; {fps:.3f} fps" if fps else f'PHASE {label} {w}x{h}',flush=True)
    return result

def main():
    p=argparse.ArgumentParser();source=p.add_mutually_exclusive_group(required=True)
    source.add_argument('--ftdi',action='store_true');source.add_argument('--capture',type=Path)
    p.add_argument('--library');p.add_argument('--simulation',action='store_true')
    p.add_argument('--word-records',action='store_true',help='Use the original per-word parser for throughput comparisons')
    p.add_argument('--blocks',action='store_true',help='Decode the 1 KB MBLK board transport')
    p.add_argument('--sync-fifo',action='store_true',help='Select synchronous FT245 (60 MHz link); also use for replay of synchronous captures')
    p.add_argument('--receive-only',action='store_true',help='Capture with framing/metadata only; verify the raw capture offline afterwards')
    p.add_argument('--pixel-cycles',type=int,choices=(1,2),help='Require this many clocks per unstalled pixel; default detects legacy/new cadence')
    p.add_argument('--core-clock-hz',type=int,default=CLOCK_HZ,help='Encoding timestamp clock: 100000000 for current MMCM firmware; default 50000000 preserves legacy captures')
    p.add_argument('--seconds',type=float,default=30);p.add_argument('--min-frames',type=int,default=6)
    p.add_argument('--first-id',type=int,default=0);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--timing-expected',type=Path)
    p.add_argument('--fps-expected',type=Path,help='Compare all snapshots against independent TB frame events')
    p.add_argument('--link-expected',type=Path,help='Compare all snapshots against independent physical CLKOUT/write counts')
    args=p.parse_args()
    if args.seconds<=0 or args.min_frames<2: p.error('positive seconds and at least two frames required')
    if args.core_clock_hz<=0: p.error('--core-clock-hz must be positive')
    if args.simulation and not args.capture: p.error('--simulation is only for replaying scaled TB frames')
    if args.receive_only and (not args.blocks or not args.ftdi): p.error('--receive-only requires --ftdi --blocks')
    args.output.mkdir(parents=True,exist_ok=True)
    if args.capture: stream=args.capture.open('rb');raw=None
    else:
        from ftdi_fifo import FtdiFifo
        stream=FtdiFifo(library=args.library,synchronous=args.sync_fifo);raw=(args.output/'usb_capture.bin').open('wb')
        (args.output/'ftdi_info.json').write_text(json.dumps(stream.eeprom_info,indent=2))
    reader=CaptureReader(stream,raw,replay=bool(args.capture))
    if args.blocks:
        from block_records import BlockRecords
        records=BlockRecords(reader.exact,collect_frames=not args.receive_only)
    else: records=BoardRecords(reader.exact)
    plan=[(48,16,b'V'),(64,24,b'H'),(96,32,b'F')] if args.simulation else [(640,480,b'V'),(1280,720,b'H'),(1920,1080,b'F')]
    results=[];first_id=args.first_id
    try:
        for w,h,command in plan:
            result=phase(records,reader,stream,w,h,command,first_id,args.output,args.seconds,args.min_frames,replay=bool(args.capture),packet_batches=not args.word_records,receive_only=args.receive_only,pixel_cycles=args.pixel_cycles,link_clock_hz=60000000 if args.sync_fifo else CLOCK_HZ,core_clock_hz=args.core_clock_hz,scaled_windows=args.simulation)
            results.append(result);first_id+=result['frames']
            (args.output/'results.json').write_text(json.dumps(results,indent=2))
        if args.capture:
            while reader.pos<len(reader.block) or stream.peek(1):
                kind,value=records.next()
                if kind not in ('fps','link'): raise ValueError('Trailing non-telemetry records')
        if args.timing_expected:
            expected=json.loads(args.timing_expected.read_text())
            if records.timings!=expected: raise ValueError('Frame timings differ from independent TB clock counts')
        for path,actual in ((args.fps_expected,records.rates),(args.link_expected,getattr(records,'links',[]))):
            if path:
                with path.open() as trace:
                    expected=[{k:int(v) for k,v in row.items()} for row in csv.DictReader(trace)]
                if actual!=expected: raise ValueError('Telemetry differs from independent TB events/physical clocks')
    finally:
        if not args.capture:
            stream.write(b'S');stream.flush()
        stream.close()
        if raw: raw.close()
    marker='CAPTURE_PASS.txt' if args.receive_only else 'VERIFY_PASS.txt'
    detail='Framing/metadata/timings checked; JPEG reference and decode verification PENDING offline replay.' if args.receive_only else 'Reference JPEG equality, independent decoding, frame sequence, frame timings and FPGA FPS/idle counts passed.'
    (args.output/marker).write_text(f'{sum(r["frames"] for r in results)} frames across three graduated resolutions. {detail}\n')
    print('PROGRESSIVE_CAPTURE_PASS' if args.receive_only else 'PROGRESSIVE_TEST_PASS',flush=True)

if __name__=='__main__':main()

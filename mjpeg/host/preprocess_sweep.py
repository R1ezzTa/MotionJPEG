"""Verify board preprocessing on independent 1080p JPEG streams.

Requires exclusive USB_SLAVE access. Modes and thresholds are applied in the
FPGA; host image operations only decode and measure received test images.
"""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import io
import json
import math
from pathlib import Path
import statistics
import time
import numpy as np
from PIL import Image
from block_records import BlockRecords
from camera_viewer import d2xx_library,preprocess_command,pixel_threshold_command,denoise_command,PREPROCESS_MODES
from denoise_sweep import _quality_table,_decode_jpeg
from ftdi_fifo import FtdiFifo

def image_statistics(data,mode):
    with Image.open(io.BytesIO(data)) as image:
        rgb=np.asarray(image.convert('RGB'),dtype=np.int16)
    chroma=int(np.max(np.max(rgb,axis=2)-np.min(rgb,axis=2)))
    y=rgb[:,:,0]
    if mode:
        assert chroma==0,'Neutral Cb/Cr did not decode as grayscale'
    return dict(max_rgb_channel_difference=chroma,min_level=int(y.min()),max_level=int(y.max()),
                mean_level=float(y.mean()),near_black_fraction=float(np.mean(y<=16)),
                near_white_fraction=float(np.mean(y>=239)))

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--settings',default='0:128:32,1:128:32,2:64:32,2:128:32,2:192:32,3:128:8,3:128:32,3:128:64,0:128:32')
    p.add_argument('--seconds',type=float,default=3)
    p.add_argument('--denoise-strength',type=int,default=0)
    p.add_argument('--serial',default='FTB7MA1D');p.add_argument('--library')
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args(argv)
    try:
        settings=[tuple(map(int,item.split(':'))) for item in args.settings.split(',')]
        assert settings and all(len(x)==3 and 0<=x[0]<4 and 0<=x[1]<=255 and 0<=x[2]<=255 for x in settings)
    except (ValueError,AssertionError):p.error('--settings must be mode:binary:edge triples')
    if not math.isfinite(args.seconds) or args.seconds<2:p.error('--seconds must be finite and at least 2')
    if not 0<=args.denoise_strength<=255:p.error('--denoise-strength must be from 0 to 255')
    args.output.mkdir(parents=True,exist_ok=True)
    source=capture_file=records=phase=None
    buffer=bytearray();phases=[];cameras=[];statuses=[];actions=[];pending=deque()
    camera=None;next_id=previous_tick=None;error=None
    began=last_data=waiting_since=time.monotonic()
    pool=ThreadPoolExecutor(max_workers=2,thread_name_prefix='preprocess-jpeg')
    expected_table=_quality_table(3)
    def command(value):
        source.write(value);source.flush()
        actions.append(dict(seconds=time.monotonic()-began,command=value.decode('ascii')))
    def check_control():
        now=time.monotonic()
        if now-last_data>10:raise TimeoutError('No USB data')
        if phase:
            if phase['state']=='running' and now-phase['start_wall']>=args.seconds:
                command(b'S');phase.update(state='stopping',stop_wall=now)
            elif phase['state']=='stopping' and now-phase['stop_wall']>5:raise TimeoutError('No END after stop')
            elif phase['state'] in ('configuring','starting') and now-phase['request_wall']>10:
                raise TimeoutError('No preprocessing readback/START')
        elif now-waiting_since>10:raise TimeoutError('Camera did not become ready and stopped')
    def exact(count):
        nonlocal last_data
        check_control()
        while len(buffer)<count:
            check_control();data=source.read_chunk()
            if data:last_data=time.monotonic();buffer.extend(data)
        value=bytes(buffer[:count]);del buffer[:count]
        if capture_file:capture_file.write(value)
        return value
    try:
        Image.init()
        source=FtdiFifo(serial=args.serial,library=d2xx_library(args.library),synchronous=True)
        command(b'l');command(b'S');records=BlockRecords(exact)
        while len(phases)<len(settings):
            kind,value=records.next();now=time.monotonic()
            if kind=='camera':
                camera=value;cameras.append(dict(value,seconds=now-began))
                assert value['preprocess_capable'] and value['denoise_capable'],'Wrong firmware capabilities'
                assert not value['threshold_capable'] and not value['adaptive_capable'],'Interframe firmware active'
                assert not any(value[name] for name in ('init_error','config_error','light_error','overflow_count')),'Camera error'
                ready=value['init_done'] and value.get('sampling_ready') and not value['streaming'] and not value['run_requested']
                if phase is None and ready:
                    mode,binary,edge=settings[len(phases)]
                    directory=args.output/f'{len(phases):02d}_{PREPROCESS_MODES[mode]}_b{binary}_e{edge}'
                    directory.mkdir(parents=True,exist_ok=True)
                    phase=dict(state='configuring',mode=mode,binary=binary,edge=edge,directory=str(directory.resolve()),
                        request_wall=now,frames=[],starts=0,ends=0,active_confirmed=False,wire_begin=records.wire_bytes)
                    capture_file=(directory/'usb_capture.bin').open('wb')
                    command(b'3');command(denoise_command(args.denoise_strength))
                    command(pixel_threshold_command(binary)+pixel_threshold_command(edge,True)+preprocess_command(mode))
            elif kind=='preprocess':
                statuses.append(dict(value,seconds=now-began))
                if phase:
                    request=(value['mode_requested'],value['binary_threshold_requested'],value['edge_threshold_requested'])
                    active=(value['mode'],value['binary_threshold'],value['edge_threshold'])
                    expected=(phase['mode'],phase['binary'],phase['edge'])
                    ready=camera and camera['init_done'] and not camera['streaming'] and not camera['run_requested']
                    if phase['state']=='configuring' and ready and request==expected and camera['quality_requested']==85 and camera['denoise_requested']==args.denoise_strength:
                        command(b'C');phase.update(state='starting',request_wall=now)
                    elif phase['state'] in ('running','stopping') and active==expected:
                        phase['active_confirmed']=True
            elif kind=='start':
                if phase is None:continue
                assert phase['state']=='starting','Unexpected START'
                phase.update(state='running',start_wall=now);phase['starts']+=1
            elif kind=='frame':
                frame=value
                assert frame.status==0 and frame.jpeg is not None,f'Failed frame {frame.frame_id}, status {frame.status}'
                assert frame.channel==0 and not frame.gray and (frame.width,frame.height)==(1920,1080),'Wrong descriptor'
                assert records.spatial_stats is None and frame.jpeg.startswith(b'\xff\xd8'),'Expected independent JPEG'
                assert next_id is None or frame.frame_id==next_id,'Frame ID gap'
                assert previous_tick is None or frame.timestamp>previous_tick,'Timestamp order'
                next_id=(frame.frame_id+1)&0xffffffff;previous_tick=frame.timestamp
                if phase is None:continue
                assert phase['state'] in ('running','stopping'),'Frame before START'
                with Image.open(io.BytesIO(frame.jpeg)) as image:
                    assert image.format=='JPEG' and image.size==(1920,1080),'Wrong JPEG'
                    assert image.quantization==expected_table,'Mixed/incomplete quality table'
                pending.append(pool.submit(_decode_jpeg,frame.jpeg,(1920,1080)))
                while pending and (pending[0].done() or len(pending)>=64):pending.popleft().result()
                if not phase['frames']:
                    (Path(phase['directory'])/'first_frame.jpg').write_bytes(frame.jpeg)
                    # Full-frame numpy statistics must not stop the USB reader.
                    phase['statistics_future']=pool.submit(image_statistics,frame.jpeg,phase['mode'])
                phase['frames'].append(dict(frame_id=frame.frame_id,timestamp=frame.timestamp,bytes=frame.length))
            elif kind=='end':
                if phase is None:waiting_since=now;continue
                assert phase['state']=='stopping' and phase['frames'] and phase['active_confirmed'],'No frames/active mode confirmation'
                phase['ends']+=1
                while pending:pending.popleft().result()
                capture_file.close();capture_file=None
                frames=phase['frames'];deltas=[b['timestamp']-a['timestamp'] for a,b in zip(frames,frames[1:])]
                assert deltas and max(deltas)<3_400_000,'Frame interval exceeded 34 ms'
                fps=100_000_000/statistics.mean(deltas);payload=sum(f['bytes'] for f in frames)
                summary=dict(mode=PREPROCESS_MODES[phase['mode']],binary_threshold=phase['binary'],edge_threshold=phase['edge'],
                    frames=len(frames),independently_decoded_frames=len(frames),starts=phase['starts'],ends=phase['ends'],
                    mean_fps=fps,max_frame_interval_ms=max(deltas)/100_000,mean_jpeg_bytes=payload/len(frames),
                    jpeg_mb_per_second=payload/len(frames)*fps/1e6,wire_bytes=records.wire_bytes-phase['wire_begin'],
                    active_confirmed=phase['active_confirmed'],first_frame_statistics=phase['statistics_future'].result(),directory=phase['directory'])
                directory=Path(phase['directory'])
                (directory/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
                (directory/'frames.json').write_text(json.dumps(frames,indent=2)+'\n')
                phases.append(summary)
                print(f"{summary['mode']:6s} B{phase['binary']:3d} E{phase['edge']:3d}: {len(frames)} frames, {fps:.4f} fps, JPEG {summary['jpeg_mb_per_second']:.3f} MB/s",flush=True)
                phase=None;waiting_since=now
            for history in (records.rates,records.timings,records.links,records.camera_status,records.preprocess_status):
                if len(history)>2:del history[:-2]
    except Exception as exc:error=f'{type(exc).__name__}: {exc}'
    finally:
        pool.shutdown(wait=True)
        if capture_file:capture_file.close()
        if source:
            try:command(b'l');command(b'S')
            finally:source.close()
    report=dict(passed=error is None,error=error,phases=phases,denoise_strength=args.denoise_strength,
        independently_decoded_frames=sum(phase['frames'] for phase in phases),seconds_per_setting=args.seconds,
        actions=actions,note='Sequential live scenes; grayscale/binary/edges change image content. JPEG may introduce grey edge pixels.')
    for name,data in (('summary',report),('camera_status',cameras),('preprocess_status',statuses)):
        (args.output/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(passed=error is None,error=error,frames=report['independently_decoded_frames'])),flush=True)
    return 1 if error else 0

if __name__=='__main__':raise SystemExit(main())

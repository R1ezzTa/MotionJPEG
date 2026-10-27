"""Collect real board evidence using the unchanged camera_viewer implementation.

Temporary task wrapper. It controls the original worker through its documented
USB commands, captures the real Tk window, and leaves the live viewer running.
"""
from pathlib import Path
from datetime import datetime
import ctypes, hashlib, io, json, sys, time, traceback
from PIL import Image, ImageGrab

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'mjpeg/host'))
import camera_viewer as cv

OUT=ROOT/'mjpeg/reports/camera/report_demo_20261026'
OUT.mkdir(parents=True,exist_ok=True)
PRE=ROOT/'work/image-previews'
PRE.mkdir(parents=True,exist_ok=True)
frames=[]
results=[]
def write_json(path,obj):
    path.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')

class LoggingWorker(cv.PreviewWorker):
    def update(self,**values):
        super().update(**values)
        if 'received' in values and self.latest:
            frame=self.latest[1]
            frames.append(dict(wall_time=time.monotonic(),frame_id=frame.frame_id,
                               timestamp=frame.timestamp,bytes=frame.length,status=frame.status))

args=cv.parse_args(['--auto-start','--save-dir',str(OUT/'manual_snapshots')])
worker=LoggingWorker(args)
window=cv.PreviewWindow(worker,args)
window.root.geometry('1120x800+20+20')
stages=[]
def stage(name,mode=0,binary=128,edge=18,quality=85,seconds=8):
    stages.append(dict(name=name,mode=mode,binary=binary,edge=edge,quality=quality,denoise=32,seconds=seconds))
stage('mode_color')
stage('mode_gray',mode=1)
for b in (64,96,128,160,192,224):stage(f'binary_t{b:03}',mode=2,binary=b)
for e in (8,18,32,64):stage(f'sobel_t{e:03}',mode=3,edge=e)
for q in (60,75,85):stage(f'quality_q{q}',quality=q,seconds=12)
stage('quality_q60_repeat',quality=60,seconds=12)
pending=None
started=None
phase='ready'
start_snapshot=None
start_time=0
initial_state=None

def current_state():return worker.snapshot()[1]
def matches(s,p):
    c=s.get('camera') or {}; pp=s.get('preprocess') or {}
    return (c.get('quality')==p['quality'] and not c.get('quality_pending')
        and c.get('denoise_requested')==32 and pp.get('mode')==p['mode']
        and pp.get('binary_threshold')==p['binary'] and pp.get('edge_threshold')==p['edge'])

def apply(p):
    worker.commands.put({60:b'1',75:b'2',85:b'3'}[p['quality']])
    window.denoise.set('32');window.apply_denoise()
    window.binary_threshold.set(str(p['binary']))
    window.edge_threshold.set(str(p['edge']))
    window.apply_preprocess(p['mode'])

def capture(p,s):
    end_time=time.monotonic()
    # Capture only the real viewer window, even if another application covers it.
    window.root.update_idletasks()
    hwnd=ctypes.windll.user32.GetParent(window.root.winfo_id())
    image=ImageGrab.grab(window=hwnd)
    full=OUT/(p['name']+'_window.png');image.save(full)
    preview=PRE/(p['name']+'_preview.jpg')
    image.thumbnail((1280,1280));image.convert('RGB').save(preview,quality=78)
    frame=window.current
    jpeg=OUT/(p['name']+'_frame.jpg');jpeg.write_bytes(frame.jpeg)
    with Image.open(io.BytesIO(frame.jpeg)) as im:
        quant_hash=hashlib.sha256(json.dumps(im.quantization,sort_keys=True).encode()).hexdigest()
    elapsed=end_time-start_time
    selected=[f for f in frames if start_time<f['wall_time']<=end_time]
    begin=start_snapshot
    jpeg_rate=(s['jpeg_bytes']-begin['jpeg_bytes'])/elapsed/1e6
    wire_rate=(s['wire_bytes']-begin['wire_bytes'])/elapsed/1e6
    mean=sum(f['bytes'] for f in selected)/len(selected)
    measured_fps=(len(selected)-1)*args.core_clock_hz/(selected[-1]['timestamp']-selected[0]['timestamp'])
    d0=begin['camera'];d1=s['camera']
    data=dict(**p,captured_at=datetime.now().astimezone().isoformat(),elapsed_seconds=elapsed,
        sample_frames=len(selected),frame_first=selected[0]['frame_id'],frame_last=selected[-1]['frame_id'],
        mean_jpeg_bytes=mean,min_jpeg_bytes=min(f['bytes'] for f in selected),max_jpeg_bytes=max(f['bytes'] for f in selected),
        fps_timestamp=measured_fps,jpeg_MBps=jpeg_rate,usb_record_MBps=wire_rate,
        yuv422_compression_ratio=1920*1080*2/mean,
        payload_reduction_percent=100*(1-mean/(1920*1080*2)),
        encoding_failed_delta=s['failed']-begin['failed'],
        overflow_delta=d1['overflow_count']-d0['overflow_count'],
        dropped_delta=d1['dropped_frames']-d0['dropped_frames'],
        screenshot=str(full.relative_to(ROOT)),preview=str(preview.relative_to(ROOT)),jpeg=str(jpeg.relative_to(ROOT)),
        displayed_frame_id=frame.frame_id,displayed_jpeg_bytes=frame.length,quantization_sha256=quant_hash,
        info_text=window.info.get(),telemetry_text=window.telemetry.get(),
        image_metadata=dict(bytes=full.stat().st_size,width=image.width,height=image.height,format='PNG'),
        preview_metadata=dict(bytes=preview.stat().st_size,width=image.width,height=image.height,format='JPEG'),
        state_start=begin,state_end=s,frames=selected)
    write_json(OUT/(p['name']+'.json'),data)
    results.append({k:v for k,v in data.items() if k not in ('state_start','state_end','frames')})
    write_json(OUT/'summary.json',dict(status='running',initial_state=initial_state,results=results))
    print(json.dumps({k:data[k] for k in ('name','sample_frames','mean_jpeg_bytes','fps_timestamp','jpeg_MBps','usb_record_MBps','dropped_delta','overflow_delta')},ensure_ascii=False),flush=True)

def loop():
    global phase,pending,started,start_snapshot,start_time,initial_state
    try:
        s=current_state()
        if s.get('error'):raise RuntimeError(s['error'])
        now=time.monotonic()
        if phase=='ready' and s.get('preprocess') and s.get('camera',{}).get('streaming'):
            initial_file=OUT/'initial_state.json'
            initial_state=json.loads(initial_file.read_text(encoding='utf-8')) if initial_file.exists() else s
            write_json(initial_file,initial_state)
            phase='next'
        if phase=='next':
            if not stages:
                # Restore the observed initial settings and keep the demo live.
                c=initial_state['camera'];pp=initial_state['preprocess']
                restore=dict(quality=c['quality'],mode=pp['mode'],binary=pp['binary_threshold'],edge=pp['edge_threshold'])
                apply(restore)
                phase='restore';started=now
                return window.root.after(250,loop)
            pending=stages.pop(0);apply(pending);started=now;phase='settle'
        elif phase=='settle':
            if now-started>20:raise RuntimeError('Board did not confirm '+str(pending))
            if now-started>=3 and matches(s,pending):
                start_snapshot=s;start_time=now;phase='sample'
        elif phase=='sample' and now-start_time>=pending['seconds']:
            if not matches(s,pending):raise RuntimeError('Settings changed during sample')
            capture(pending,s);phase='next'
        elif phase=='restore' and now-started>3:
            write_json(OUT/'summary.json',dict(status='complete',initial_state=initial_state,final_state=s,results=results))
            print('CAPTURE_COMPLETE: restored initial board controls; live viewer remains open',flush=True)
            return
        window.root.after(150,loop)
    except Exception as exc:
        write_json(OUT/'error.json',dict(error=str(exc),traceback=traceback.format_exc(),state=current_state()))
        print(traceback.format_exc(),flush=True)

worker.start()
window.root.after(1000,loop)
try:window.root.mainloop()
finally:
    worker.stop.set();worker.join(10);window.preparation.close();window.preparation.join(5)

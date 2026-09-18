"""Summarize live/deferred hardware measurements only after offline validation."""
import argparse,hashlib,json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
CLOCK_HZ=50000000
def load(path): return json.loads(path.read_text(encoding='utf-8-sig'))
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda:source.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--live',type=Path,required=True);p.add_argument('--receive',type=Path,required=True)
    p.add_argument('--build',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--baseline',type=Path,default=ROOT/'reports/mjpeg_board_test/hardware_throughput_batched_20260918/results.json')
    p.add_argument('--recovery',type=Path,help='Optional pending-data clock reset hardware test directory')
    args=p.parse_args()
    live=load(args.live/'results.json');receive=load(args.receive/'results.json')
    offline=load(args.receive/'verified_offline/results.json')
    baseline=load(args.baseline)
    if not len(live)==len(receive)==len(offline)==3: raise ValueError('Missing graduated phases')
    comparisons=[]
    link_clock_hz=live[0].get('link_clock_hz',CLOCK_HZ)
    synchronous=link_clock_hz==60000000
    core_clock_hz=live[0].get('core_clock_hz',CLOCK_HZ)
    if link_clock_hz not in (CLOCK_HZ,60000000): raise ValueError('Unknown physical link clock')
    stable_keys=('width','height','frames','first_frame_id','last_frame_id','jpeg_bytes_per_frame','jpeg_sha256',
                 'start_interval_fps','mean_feed_ms','mean_jpeg_end_ms','mean_descriptor_end_ms',
                 'input_wait_fraction','output_wait_fraction','wire_start_offset','wire_end_offset','link_totals')
    for old,a,b,c in zip(baseline,live,receive,offline):
        if (old['width'],old['height'],old['quality'],old['jpeg_sha256'])!=(a['width'],a['height'],a['quality'],a['jpeg_sha256']):
            raise ValueError('Baseline dimensions, quality or JPEG differ')
        if not a['passed'] or not c['passed'] or not b['receive_only']: raise ValueError('Missing JPEG verification')
        if any(b[k]!=c[k] for k in stable_keys): raise ValueError('Offline metrics differ from captured data')
        pixels=a['pixels'];pixel_cycles=a.get('pixel_cycles',2)
        if any(r.get('link_clock_hz',CLOCK_HZ)!=link_clock_hz for r in (a,b,c)):
            raise ValueError('Link clock differs between runs')
        if any(r.get('core_clock_hz',CLOCK_HZ)!=core_clock_hz for r in (a,b,c)):
            raise ValueError('Encoding clock differs between runs')
        if pixel_cycles not in (1,2) or b.get('pixel_cycles',2)!=pixel_cycles or c.get('pixel_cycles',2)!=pixel_cycles:
            raise ValueError('Pixel cadence differs between compared runs')
        source_ceiling=core_clock_hz/(pixel_cycles*pixels)
        row={'width':a['width'],'height':a['height'],'baseline_fps':old['start_interval_fps'],
             'live_fps':a['start_interval_fps'],'receive_only_fps':b['start_interval_fps'],
             'speedup':a['start_interval_fps']/old['start_interval_fps'],
             'receive_only_gain_fraction':b['start_interval_fps']/a['start_interval_fps']-1,
             'pixel_cycles':pixel_cycles,'source_fps_ceiling':source_ceiling,
             'link_clock_hz':link_clock_hz,
             'core_clock_hz':core_clock_hz,'baseline_core_clock_hz':old.get('core_clock_hz',CLOCK_HZ),
             'async_reference_clock_hz':CLOCK_HZ,
             'async_six_cycle_fps_ceiling':(CLOCK_HZ/6)/(a['jpeg_bytes_per_frame']*a['wire_expansion']),
             'source_ceiling_fraction':a['start_interval_fps']/source_ceiling,
             'live_wire_mbytes_s':a['steady_wire_mbytes_s'],'receive_wire_mbytes_s':b['steady_wire_mbytes_s'],
             'live_cycle_fractions':a['link_cycle_fractions'],'receive_cycle_fractions':b['link_cycle_fractions'],
             'live_host_cpu_fraction':a['host_cpu_fraction'],'receive_host_cpu_fraction':b['host_cpu_fraction'],
             'input_wait_fraction':a['input_wait_fraction'],'mean_feed_ms':a['mean_feed_ms'],
             'source_ideal_feed_ms':pixel_cycles*(pixels-1)*1000/core_clock_hz,
             'wire_expansion':a['wire_expansion'],'jpeg_bytes_per_frame':a['jpeg_bytes_per_frame']}
        comparisons.append(row)
    reset_between_runs=live[-1]['last_frame_id']+1!=receive[0]['first_frame_id']
    if reset_between_runs and not (synchronous and live[0]['first_frame_id']==receive[0]['first_frame_id']==0):
        raise ValueError('Unexpected frame ID reset between runs')
    for root in (args.live,args.receive):
        results=load(root/'results.json')
        for left,right in zip(results,results[1:]):
            if left['last_frame_id']+1!=right['first_frame_id']: raise ValueError('Frame sequence gap')
        if results[-1]['wire_end_offset']> (root/'usb_capture.bin').stat().st_size: raise ValueError('Capture is shorter than parsed offsets')
    hashes=load(args.build/'build_hashes.json')
    for entry in hashes:
        if digest(Path(entry['Path'])).upper()!=entry['Hash'].upper(): raise ValueError('Build source/artifact changed: '+entry['Path'])
    captures=[{'path':str(root/'usb_capture.bin'),'bytes':(root/'usb_capture.bin').stat().st_size,
               'sha256':digest(root/'usb_capture.bin')} for root in (args.live,args.receive)]
    recovery=None
    if args.recovery:
        recovery=load(args.recovery/'recovery_result.json')
        recovered=load(args.recovery/'frames.json')
        if not (synchronous and recovery['passed'] and recovery['pending_1080p_usb_bytes']>0
                and recovery['first_recovered_frame_id']==0
                and recovery['verified_recovered_frames']==len(recovered)==27
                and [f['frame_id'] for f in recovered]==list(range(27))
                and all(f['reference_equal'] and f['decoded'] for f in recovered)):
            raise ValueError('Pending-data clock reset recovery was not verified')
        capture=args.recovery/'usb_capture.bin'
        captures.append({'path':str(capture),'bytes':capture.stat().st_size,'sha256':digest(capture)})
    sources={str(path.relative_to(ROOT)):digest(path) for directory in ('rtl','tb','host','scripts')
             for path in (ROOT/directory).rglob('*') if path.is_file() and path.suffix in ('.v','.vh','.sv','.py','.ps1','.tcl')}
    evidence={'clock_hz':core_clock_hz,'core_clock_hz':core_clock_hz,'block_payload_bytes':1024,'double_buffer_bytes':2048,
              'physical_transport':('FT245 synchronous FIFO, 8KiB TX / 256B RX CDC, clock-loss reset; EEPROM unchanged' if synchronous else 'FT245 asynchronous FIFO; EEPROM unchanged'),
              'link_clock_hz':link_clock_hz,'frame_ids_reset_between_runs':reset_between_runs,
              'cdc_tx_fifo_bytes':8192 if synchronous else 0,'cdc_rx_fifo_bytes':256 if synchronous else 0,
              'clock_reset_recovery':recovery,
              'pixel_source':f'{live[0].get("pixel_cycles",2)} clock cycle(s) per unstalled pixel, existing full-resolution gradient',
              'baseline':str(args.baseline),
              'live_frames':sum(r['frames'] for r in live),'receive_frames':sum(r['frames'] for r in receive),
              'total_reference_equal_decoded_frames':sum(r['frames'] for r in live+offline),
              'last_total_compressed':receive[-1]['last_frame_id']+1,'comparisons':comparisons,
              'build':str(args.build),'bitstream_sha256':digest(args.build/'davinci_mjpeg_board_test.bit'),
              'build_hashes_verified':True,'source_sha256':sources,'raw_captures':captures,
              'all_receive_only_frames_verified_offline':True,'stopped_idle_windows_per_phase':2,'passed':True}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(evidence,indent=2),encoding='utf-8')
    print(json.dumps({'frames':evidence['total_reference_equal_decoded_frames'],'comparisons':comparisons},indent=2))

if __name__=='__main__':main()

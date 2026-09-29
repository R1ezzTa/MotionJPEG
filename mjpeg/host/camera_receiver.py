"""Capture real OV5640 JPEGs, independent decode and bandwidth diagnostics.

Uses the same MBLK framing as the synthetic source, but never compares camera
pixels or encoded bytes against a test pattern. C starts; S drains at a frame
boundary. A raw capture can be verified again without connected hardware.
"""
import argparse
import hashlib
import io
import json
import math
import statistics
import time
from pathlib import Path

from PIL import Image
from block_records import BlockRecords


class CameraFrames:
    def __init__(self, width=640, height=480, save_count=5, destination=None,
                 first_id=None):
        self.width=width;self.height=height;self.save_count=save_count
        self.destination=destination;self.next_id=first_id
        self.frames=[];self.previous_timestamp=None

    def accept(self, frame):
        metadata={k:v for k,v in vars(frame).items() if k!='jpeg'}
        metadata['decoded']=False
        self.frames.append(metadata)
        if self.next_id is None: self.next_id=frame.frame_id
        if frame.frame_id!=self.next_id:
            raise ValueError(f'Frame sequence: expected {self.next_id}, received {frame.frame_id}')
        self.next_id=(self.next_id+1)&0xffffffff
        if (frame.channel,frame.width,frame.height,frame.gray)!=(0,self.width,self.height,False):
            raise ValueError(f'Unexpected camera frame format: {metadata}')
        if self.previous_timestamp is not None and frame.timestamp<=self.previous_timestamp:
            raise ValueError('Camera timestamp did not increase')
        self.previous_timestamp=frame.timestamp
        if frame.status:
            metadata['error']=f'Encoder rejected camera frame, status={frame.status:#x}'
            # Retain failed descriptors and drain subsequent frames: an abort
            # should not hide whether the camera/FIFO recovers successfully.
            return metadata
        if frame.jpeg is None: raise ValueError('Successful descriptor has no JPEG')
        if len(frame.jpeg)!=frame.length: raise ValueError('JPEG length differs from descriptor')
        metadata['sha256']=hashlib.sha256(frame.jpeg).hexdigest()
        if self.destination is not None and len(self.frames)<=self.save_count:
            name=f'camera{frame.channel}_frame{frame.frame_id}.jpg'
            (self.destination/name).write_bytes(frame.jpeg)
            metadata['saved_jpeg']=name
        # Pillow is an independent JPEG decoder; fully decompress every frame.
        with Image.open(io.BytesIO(frame.jpeg)) as image:
            if image.format!='JPEG' or image.size!=(self.width,self.height):
                raise ValueError('Independent decoder format/dimension mismatch')
            image.load()
            metadata['decoded_mode']=image.mode
        metadata['decoded']=True
        metadata['raw_yuv422_bytes']=self.width*self.height*2
        metadata['compression_ratio']=metadata['raw_yuv422_bytes']/frame.length
        return metadata


def diagnose_camera(statuses,decoded_frames):
    """Infer likely fault areas; counters confirm activity, not precise timing."""
    if not statuses:
        return ['No camera status received: check bitstream, USB FIFO mode and transport.']
    first,last=statuses[0],statuses[-1]
    hints=[]
    if last['init_done'] and last.get('sampling_ready') is False:
        hints.append('Sensor registers initialized but the sampling clock/reset is not ready; check camera MMCM lock.')
    if last.get('light_error'):
        hints.append('Runtime light SCCB write/readback failed; sensor reset was asserted to turn off the STROBE output. Reopen the device to reinitialize.')
    elif last['init_error']:
        phase=('chip-ID read' if last['config_index']<2 else
               'register writes' if last['config_index']<262 else 'register readback')
        hints.append(f'SCCB initialization failed during {phase} at index {last["config_index"]}; chip ID={last["chip_id"]&65535:04x}. ACK/error-code details are not in this status packet.')
    elif not last['init_done']:
        hints.append('SCCB initialization has not completed; check configuration progress before diagnosing the video path.')
    if last['init_done'] and last['chip_id']&65535!=0x5640:
        hints.append('Unexpected sensor chip ID despite initialization completion.')
    if last['config_error']:
        hints.append('JPEG codec configuration error is asserted.')
    if last['init_done'] and not last['tables_ready']:
        hints.append('JPEG quantization tables are not ready; camera admission remains disabled.')
    if len(statuses)>=2:
        delta={k:(last[k]-first[k])&0xffffffff for k in
               ('pclk_ticks','dvp_byte_count','received_frames','dropped_frames','overflow_count')}
        if last['init_done'] and not delta['pclk_ticks']:
            hints.append('No PCLK counter advance across status samples: inspect camera clock/output enable, module clock and pin connection.')
        elif delta['pclk_ticks'] and not delta['dvp_byte_count']:
            hints.append('PCLK advances but no HREF-active bytes: inspect DVP output enable and HREF/VSYNC polarity or connection.')
        if delta['overflow_count']:
            hints.append(f'Capture FIFO overflow increased by {delta["overflow_count"]}: check encoder/output backpressure and buffer capacity.')
        if delta['dvp_byte_count'] and not delta['received_frames']:
            hints.append('Video bytes advance without a complete captured frame: check admission, line/frame dimensions and capture faults.')
        if delta['dropped_frames']:
            hints.append('Dropped-frame count increased; it includes intentional admission skips while idle/stopping/busy and capture faults, so it alone does not prove overflow.')
    elif not last['pclk_ticks'] and last['init_done']:
        hints.append('PCLK has not been observed since reset; additional status samples are needed to confirm continuing clock activity.')
    if decoded_frames==0 and last['received_frames']:
        hints.append('Complete capture frames exist but no JPEG decoded: inspect codec state, failed descriptors and USB transport.')
    if decoded_frames:
        hints.append('JPEG decode succeeded; frame counters and byte counters should still be checked for drops/overflow.')
    return hints


def summarize(frames, records, core_clock_hz=100_000_000, target_fps=15):
    verified=[f for f in frames if f.get('decoded') and f['status']==0]
    result={'received_frames':len(frames),'decoded_frames':len(verified),
            'failed_frames':sum(bool(f['status']) for f in frames),
            'payload_bytes':records.payload_bytes,'wire_bytes':records.wire_bytes,
            'payload_blocks':records.payload_blocks,'core_clock_hz':core_clock_hz,
            'target_fps':target_fps}
    result['camera_diagnostics']=diagnose_camera(records.camera_status,len(verified))
    if records.camera_status:
        result['last_camera_status']=records.camera_status[-1]
        first,last=records.camera_status[0],records.camera_status[-1]
        # Sum adjacent samples: at 84 MHz PCLK wraps every 51.1 seconds,
        # so first/last subtraction alone loses a wrap in a 60-second run.
        result['camera_counter_deltas']={key:sum((b[key]-a[key])&0xffffffff for a,b in zip(records.camera_status,records.camera_status[1:])) for key in
            ('pclk_ticks','received_frames','dropped_frames','overflow_count','dvp_byte_count')}
        if 'frame_sync_count' in first and 'frame_sync_count' in last:
            result['camera_counter_deltas']['frame_sync_count']=sum((b['frame_sync_count']-a['frame_sync_count'])&0xffffffff for a,b in zip(records.camera_status,records.camera_status[1:]))
        seconds=last.get('window',0)-first.get('window',0)
        if seconds>0:
            result['camera_sample_seconds']=seconds
            result['camera_pclk_hz_measured']=result['camera_counter_deltas']['pclk_ticks']/seconds
            result['camera_dvp_bytes_per_second_measured']=result['camera_counter_deltas']['dvp_byte_count']/seconds
            if 'frame_sync_count' in result['camera_counter_deltas']:
                result['camera_vsync_fps_measured']=result['camera_counter_deltas']['frame_sync_count']/seconds
    if records.rates: result['last_fps']=records.rates[-1]
    if not verified: return result
    sizes=sorted(f['length'] for f in verified)
    raw=sum(f['raw_yuv422_bytes'] for f in verified)
    jpeg=sum(sizes);mean=statistics.mean(sizes)
    raw8=bool(records.camera_status) and records.camera_status[-1].get('raw8',False)
    sensor_raw=raw//2 if raw8 else raw
    p95=sizes[max(0,math.ceil(len(sizes)*0.95)-1)]
    result.update({'dimensions':[verified[0]['width'],verified[0]['height']],
        'first_frame_id':verified[0]['frame_id'],'last_frame_id':verified[-1]['frame_id'],
        'jpeg_bytes_total':jpeg,'jpeg_bytes_mean':mean,'jpeg_bytes_p95':p95,
        'jpeg_bytes_max':max(sizes),'raw_yuv422_bytes_total':raw,
        'compression_ratio':raw/jpeg,'bandwidth_reduction_percent':100*(1-jpeg/raw),
        'sensor_format':'RAW8 BGGR' if raw8 else 'YUV422 YUYV',
        'sensor_bytes_total':sensor_raw,'sensor_compression_ratio':sensor_raw/jpeg,
        'sensor_bandwidth_reduction_percent':100*(1-jpeg/sensor_raw),
        'raw_bytes_per_second_at_target_fps':verified[0]['raw_yuv422_bytes']*target_fps,
        'jpeg_bytes_per_second_at_target_fps':mean*target_fps,
        'jpeg_bits_per_second_at_target_fps':mean*target_fps*8})
    if len(verified)>1:
        ticks=verified[-1]['timestamp']-verified[0]['timestamp']
        if ticks>0:
            fps=(len(verified)-1)*core_clock_hz/ticks
            result['timestamp_fps']=fps
            result['jpeg_bytes_per_second_measured']=mean*fps
            result['sensor_bytes_per_second_at_jpeg_fps']=sensor_raw/len(verified)*fps
    return result


def validate_performance(result, target_fps, require_no_drops=False):
    """Reject a valid JPEG stream that falls short of the requested load."""
    fps=result.get('timestamp_fps',0)
    if abs(fps-target_fps)>target_fps*0.02:
        raise ValueError(f'Measured JPEG FPS {fps:.4f} differs from target {target_fps:g} by more than 2%')
    if 'camera_vsync_fps_measured' in result and abs(result['camera_vsync_fps_measured']-target_fps)>target_fps*0.02:
        raise ValueError(f'Measured camera VSYNC FPS {result["camera_vsync_fps_measured"]:.4f} differs from target {target_fps:g}')
    if require_no_drops:
        if 'camera_counter_deltas' not in result:
            raise ValueError('At least two camera status windows are needed to check steady-state drops')
        delta=result['camera_counter_deltas']
        if delta['dropped_frames'] or delta['overflow_count'] or result['last_camera_status']['overflow_count']:
            raise ValueError(f'Steady-state capture drops/overflow: {delta}')


class CameraReader:
    def __init__(self, source, capture=None, replay=False, duration=10, drain_timeout=30,
                 light_pulse=False,light_after=2):
        self.source=source;self.capture=capture;self.replay=replay
        self.buffer=bytearray();self.offset=0;self.stopped=replay
        self.began=time.monotonic();self.duration=duration;self.drain_timeout=drain_timeout
        self.light_pulse=light_pulse;self.light_after=light_after
        self.seen_frame=False;self.light_started=None;self.light_stopped=False;self.light_events=[]

    def light_command(self, turn_on):
        self.source.write(b'L' if turn_on else b'l');self.source.flush()
        self.light_events.append({'command':'L' if turn_on else 'l','elapsed_seconds':time.monotonic()-self.began})
        print('LIGHT pulse requested (hardware limit 2 seconds)' if turn_on else 'LIGHT off requested',flush=True)

    def check_stop(self):
        if self.replay: return
        elapsed=time.monotonic()-self.began
        if self.light_pulse and not self.stopped:
            if self.light_started is None and self.seen_frame and elapsed>=self.light_after and elapsed<self.duration:
                self.light_command(True);self.light_started=elapsed
            elif self.light_started is not None and not self.light_stopped and elapsed>=self.light_started+2:
                # Do not send l here: live telemetry must demonstrate that
                # the FPGA timer itself turned the light off.
                self.light_stopped=True
        if not self.stopped and elapsed>=self.duration:
            if self.light_pulse:
                self.light_command(False);self.light_stopped=True
            self.source.write(b'S');self.source.flush();self.stopped=True
            print('STOP sent; waiting for complete frame and END',flush=True)
        if elapsed>self.duration+self.drain_timeout:
            raise TimeoutError('No complete END after camera stop; inspect camera_status.json')

    def exact(self,n):
        while len(self.buffer)<n:
            self.check_stop()
            data=self.source.read(65536) if self.replay else self.source.read_chunk()
            if not data:
                if self.replay: raise EOFError('Capture ended before END or inside an MBLK record')
                continue
            if self.capture: self.capture.write(data)
            self.buffer.extend(data)
        data=bytes(self.buffer[:n]);del self.buffer[:n];self.offset+=n
        self.check_stop()
        return data


def read_camera_session(records, frames, reader):
    started=False
    while True:
        kind,value=records.next()
        if kind=='start':
            if started: raise ValueError('Unexpected second START')
            started=True
        elif kind=='frame':
            if not started: raise ValueError('Camera frame before START')
            row=frames.accept(value)
            reader.seen_frame=True
            if len(frames.frames)<=5 or len(frames.frames)%30==0:
                label='DECODED' if row['decoded'] else f"FAILED status={row['status']:#x}"
                print(f"FRAME {row['frame_id']} {row['width']}x{row['height']} JPEG={row['length']} bytes {label}",flush=True)
        elif kind=='camera':
            print(f"CAM init={value['init_done']} error={value['init_error']} chip={value['chip_id']&0xffff:04x} config={value['config_index']} pclk={value['pclk_ticks']} vsync={value.get('frame_sync_count','n/a')} frames={value['received_frames']} dropped={value['dropped_frames']} overflow={value['overflow_count']} bytes={value['dvp_byte_count']}",flush=True)
            if reader.light_pulse:
                print(f"LIGHT requested={value['light_requested']} on_readback={value['light_on']} busy={value['light_busy']} error={value['light_error']}",flush=True)
        elif kind=='fps':
            print(f"FPS input={value['input_fps']} jpeg={value['compressed_fps']} failed={value['failed_fps']}",flush=True)
        elif kind=='end':
            if not started: raise ValueError('END without START')
            if not reader.replay and not reader.stopped: raise ValueError('Camera stopped before S command')
            return


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    source=parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--ftdi',action='store_true')
    source.add_argument('--capture',type=Path)
    parser.add_argument('--serial',default='FTB7MA1D')
    parser.add_argument('--library',help='D2XX DLL/SO path')
    parser.add_argument('--duration',type=float,default=10)
    parser.add_argument('--drain-timeout',type=float,default=30)
    parser.add_argument('--width',type=int,default=640)
    parser.add_argument('--height',type=int,default=480)
    parser.add_argument('--save-count',type=int,default=5)
    parser.add_argument('--light-pulse',action='store_true',help='Request one 2-second light pulse during live capture')
    parser.add_argument('--light-after',type=float,default=2,help='Seconds before pulse, also wait for a decoded frame')
    parser.add_argument('--first-id',type=int,help='By default accept initial ID, then require continuity')
    parser.add_argument('--core-clock-hz',type=int,default=100_000_000)
    parser.add_argument('--target-fps',type=float,default=15)
    parser.add_argument('--require-fps',type=float,help='Require measured JPEG FPS within 2%% of this target')
    parser.add_argument('--require-no-drops',action='store_true',help='Reject steady-window drops or any FIFO overflow')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if min(args.duration,args.drain_timeout,args.width,args.height,args.core_clock_hz,args.target_fps)<=0 or args.save_count<0:
        parser.error('Durations/dimensions/clocks/FPS must be positive; save count cannot be negative')
    if args.light_after<0 or (args.light_pulse and (args.capture or args.duration<args.light_after+3)):
        parser.error('Light pulse requires live capture, nonnegative delay and at least 3 seconds remaining')
    if args.require_fps is not None and args.require_fps<=0:
        parser.error('Required FPS must be positive')
    if args.require_no_drops and args.require_fps is None:
        parser.error('--require-no-drops requires --require-fps')
    args.output.mkdir(parents=True,exist_ok=True)
    if args.capture and args.capture.resolve()==(args.output/'usb_capture.bin').resolve():
        parser.error('Replay output must not overwrite input capture')
    frames=CameraFrames(args.width,args.height,args.save_count,args.output,args.first_id)
    stream=None;capture=None;reader=None;records=None;error=None
    try:
        if args.capture:
            stream=args.capture.open('rb')
        else:
            from ftdi_fifo import FtdiFifo
            stream=FtdiFifo(serial=args.serial,library=args.library,synchronous=True)
            (args.output/'ftdi_info.json').write_text(json.dumps(stream.eeprom_info,indent=2),encoding='utf-8')
            capture=(args.output/'usb_capture.bin').open('wb')
        reader=CameraReader(stream,capture,bool(args.capture),args.duration,args.drain_timeout,args.light_pulse,args.light_after)
        records=BlockRecords(reader.exact)
        if not args.capture: stream.write(b'C');stream.flush()
        read_camera_session(records,frames,reader)
        if args.capture:
            # Idle telemetry may follow END; reject any second stream/frame.
            while reader.buffer or stream.peek(1):
                if records.next()[0] not in ('fps','link','camera'):
                    raise ValueError('Unexpected stream data after END')
        if not frames.frames: raise ValueError('No camera JPEG received; inspect camera_status.json')
        if any(f['status'] for f in frames.frames):
            raise ValueError('Camera session contains failed encoder frames; inspect frames.json and camera_status.json')
        if args.light_pulse:
            if not any(s['light_on'] for s in records.camera_status):
                raise ValueError('No light-on register readback observed')
            if any(s['light_error'] for s in records.camera_status) or not records.camera_status or records.camera_status[-1]['light_on']:
                raise ValueError('Light error or no final off confirmation; inspect camera_status.json')
        if args.require_fps is not None:
            validate_performance(summarize(frames.frames,records,args.core_clock_hz,args.target_fps),args.require_fps,args.require_no_drops)
    except Exception as exc:
        error=f'{type(exc).__name__}: {exc}'
    finally:
        if stream is not None:
            if not args.capture and args.light_pulse:
                try: stream.write(b'l');stream.flush()
                except Exception as exc:
                    if error is None: error=f'Light off failed: {exc}'
            if not args.capture and (reader is None or not reader.stopped):
                try: stream.write(b'S');stream.flush()
                except Exception as exc:
                    if error is None: error=f'Stop failed: {exc}'
            try: stream.close()
            except Exception as exc:
                if error is None: error=f'Close failed: {exc}'
        if capture is not None: capture.close()
        if records is None: records=BlockRecords(lambda n:b'')
        for name,value in [('frames',frames.frames),('fps',records.rates),('timings',records.timings),
                           ('link_windows',records.links),('camera_status',records.camera_status)]:
            (args.output/f'{name}.json').write_text(json.dumps(value,indent=2),encoding='utf-8')
        result=summarize(frames.frames,records,args.core_clock_hz,args.target_fps)
        result.update({'pass':error is None,'error':error})
        if args.require_fps is not None:
            result.update({'required_fps':args.require_fps,'require_no_drops':args.require_no_drops})
        if reader is not None:
            result['light_events']=reader.light_events
        if args.light_pulse:
            result['light_on_readback_seen']=any(s['light_on'] for s in records.camera_status)
            result['light_final_off_readback']=bool(records.camera_status) and not records.camera_status[-1]['light_on']
        (args.output/'summary.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print(json.dumps(result,indent=2),flush=True)
    if error: raise SystemExit(error)


if __name__=='__main__': main()

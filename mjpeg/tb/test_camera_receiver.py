"""Real-camera framing/decode regression, including variable JPEG contents."""
import io
import struct
import sys
import unittest
from pathlib import Path

from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from block_records import BlockRecords
from camera_receiver import CameraFrames,CameraReader,read_camera_session,summarize,diagnose_camera,validate_performance
from mjpeg_receiver import Frame


def block(kind,body=b'',flags=0):
    return struct.pack('<4sBBH',b'MBLK',kind,flags,len(body))+body


def jpeg(color,width=16,height=8):
    output=io.BytesIO();Image.new('RGB',(width,height),color).save(output,format='JPEG')
    return output.getvalue()


def frame_blocks(frame_id,timestamp,data,width=16,height=8):
    packets=[]
    for offset in range(0,len(data),150):
        flags=int(offset==0)|2*int(offset+150>=len(data))
        packets.append(block(0,struct.pack('<I',frame_id)+data[offset:offset+150],flags))
    packets.append(block(1,struct.pack('<7I',0x4d4a1400,frame_id,timestamp,0,len(data),width|height<<16,0)))
    return b''.join(packets)


class CameraTests(unittest.TestCase):
    def test_sampling_clock_status_and_legacy_compatibility(self):
        for flags,expected in [(0x9049,False),(0xd049,True),(0x1049,None)]:
            reader=CameraReader(io.BytesIO(block(7,struct.pack('<8I',flags,0x5640,277,0,0,1,0,0))),replay=True)
            status=BlockRecords(reader.exact).next()[1]
            self.assertIs(status.get('sampling_ready'),expected)
            hints=diagnose_camera([status],0)
            self.assertEqual(any('MMCM lock' in hint for hint in hints),expected is False)

    def test_long_run_counter_wrap_preserves_clock_rate(self):
        data=b''
        for window in range(1,61):
            count=30*window
            data+=block(2,struct.pack('<5I',window,30,30,0,count))
            data+=block(7,struct.pack('<8I',0x1049,(count&0xffff)<<16|0x5640,277,
                                     (4_000_000_000+84_000_000*(window-1))&0xffffffff,count,1,0,100*window))
        reader=CameraReader(io.BytesIO(data),replay=True);records=BlockRecords(reader.exact)
        for _ in range(120): records.next()
        result=summarize([],records)
        self.assertEqual(result['camera_counter_deltas']['pclk_ticks'],84_000_000*59)
        self.assertEqual(result['camera_pclk_hz_measured'],84_000_000)
        self.assertEqual(result['camera_vsync_fps_measured'],30)

    def test_raw8_bandwidth_does_not_count_internal_yuv_expansion(self):
        camera=block(7,struct.pack('<8I',0x3049,0x5640,277,84_000_000,30,1,0,128))
        data=block(6)+camera+frame_blocks(0,1000,jpeg('red'))+block(5)
        reader=CameraReader(io.BytesIO(data),replay=True)
        records=BlockRecords(reader.exact);frames=CameraFrames(16,8)
        read_camera_session(records,frames,reader)
        result=summarize(frames.frames,records)
        self.assertEqual(result['sensor_format'],'RAW8 BGGR')
        self.assertEqual(result['sensor_bytes_total'],128)
        self.assertEqual(result['raw_yuv422_bytes_total'],256)
        self.assertAlmostEqual(result['sensor_compression_ratio'],128/frames.frames[0]['length'])
        self.assertAlmostEqual(result['compression_ratio'],2*result['sensor_compression_ratio'])

    def test_extended_vsync_counter_and_legacy_status(self):
        count=0x345612ab
        words=(0x1049,0x12ab5640,0x34560112,48000000,30,1,0,18432000)
        reader=CameraReader(io.BytesIO(block(7,struct.pack('<8I',*words))),replay=True)
        status=BlockRecords(reader.exact).next()[1]
        self.assertEqual(status['frame_sync_count'],count)
        self.assertEqual(status['chip_id'],0x5640)
        self.assertEqual(status['config_index'],274)
        reader=CameraReader(io.BytesIO(block(7,struct.pack('<8I',0x49,0x5640,270,1,1,0,0,1))),replay=True)
        self.assertNotIn('frame_sync_count',BlockRecords(reader.exact).next()[1])

    def test_performance_target_rejects_slow_or_dropped_valid_stream(self):
        good={'timestamp_fps':30.01,'camera_counter_deltas':{'dropped_frames':0,'overflow_count':0},'last_camera_status':{'overflow_count':0}}
        validate_performance(good,30,True)
        with self.assertRaisesRegex(ValueError,'Measured JPEG FPS'):
            validate_performance(dict(good,timestamp_fps=15),30,True)
        with self.assertRaisesRegex(ValueError,'drops/overflow'):
            validate_performance(dict(good,camera_counter_deltas={'dropped_frames':2,'overflow_count':0}),30,True)
        with self.assertRaisesRegex(ValueError,'two camera status'):
            validate_performance({'timestamp_fps':30},30,True)
    def test_light_flags_and_default_off_compatibility(self):
        for flags,expected in [(0x49,(False,False,False,False)),(0xf49,(True,True,True,True)),(0x249,(False,True,False,False))]:
            reader=CameraReader(io.BytesIO(block(7,struct.pack('<8I',flags,0x5640,270,1,1,0,0,1))),replay=True)
            status=BlockRecords(reader.exact).next()[1]
            self.assertEqual(tuple(status[k] for k in ('light_requested','light_on','light_error','light_busy')),expected)

    def test_light_pulse_waits_for_frame_and_leaves_timeout_to_fpga(self):
        class Commands:
            def __init__(self): self.sent=[]
            def write(self,data): self.sent.append(data)
            def flush(self): pass
        stream=Commands();reader=CameraReader(stream,duration=10,light_pulse=True,light_after=2)
        reader.began-=2.5;reader.check_stop()
        self.assertEqual(stream.sent,[])
        reader.seen_frame=True;reader.check_stop()
        self.assertEqual(stream.sent,[b'L'])
        reader.began-=2.5;reader.check_stop()
        self.assertEqual(stream.sent,[b'L'])
        reader.began-=5;reader.check_stop()
        self.assertEqual(stream.sent,[b'L',b'l',b'S'])

    def test_real_frames_decode_without_reference_and_all_telemetry(self):
        camera=block(7,struct.pack('<8I',0x49,0x5640,213,100,3,1,0,614400))
        fps=block(2,struct.pack('<5I',1,2,2,0,2))
        timing=block(3,struct.pack('<6I',6,100,110,120,5,10))
        link=block(4,struct.pack('<7I',1,100,20,20,20,30,10))
        data=block(6)+camera+frame_blocks(6,1000,jpeg('red'))+timing+fps+link+frame_blocks(7,2000,jpeg('green'))+block(5)
        reader=CameraReader(io.BytesIO(data),replay=True)
        records=BlockRecords(reader.exact);frames=CameraFrames(16,8)
        read_camera_session(records,frames,reader)
        self.assertEqual([f['frame_id'] for f in frames.frames],[6,7])
        self.assertTrue(all(f['decoded'] for f in frames.frames))
        self.assertNotEqual(frames.frames[0]['sha256'],frames.frames[1]['sha256'])
        self.assertEqual(records.camera_status[0]['chip_id'],0x5640)
        self.assertEqual(records.camera_status[0]['dvp_byte_count'],614400)
        self.assertTrue(records.camera_status[0]['init_done'])
        self.assertFalse(records.camera_status[0]['init_error'])
        self.assertEqual(records.timings[0]['frame_id'],6)
        self.assertEqual(records.links[0]['writes'],20)
        result=summarize(frames.frames,records,100_000_000)
        self.assertEqual(result['decoded_frames'],2)
        self.assertEqual(result['timestamp_fps'],100_000)
        self.assertAlmostEqual(result['compression_ratio'],512/sum(f['length'] for f in frames.frames))
        self.assertEqual(result['jpeg_bytes_p95'],max(f['length'] for f in frames.frames))

    def test_rejects_gap_dimensions_status_and_corrupt_decoder(self):
        def frame(frame_id=0,width=16,status=0,data=None):
            payload=jpeg('red') if data is None else data
            return Frame(0,frame_id,frame_id+1,width,8,False,status,len(payload),payload)
        frames=CameraFrames(16,8);frames.accept(frame())
        with self.assertRaisesRegex(ValueError,'sequence'): frames.accept(frame(2))
        with self.assertRaisesRegex(ValueError,'format'): CameraFrames(16,8).accept(frame(width=32))
        failed=CameraFrames(16,8)
        self.assertFalse(failed.accept(frame(status=1))['decoded'])
        self.assertTrue(failed.accept(frame(frame_id=1))['decoded'])
        self.assertEqual(summarize(failed.frames,BlockRecords(lambda n:b''))['failed_frames'],1)
        with self.assertRaises(Exception): CameraFrames(16,8).accept(frame(data=b'\xff\xd8garbage\xff\xd9'))

    def test_camera_bad_length_and_idle_diagnostics(self):
        reader=CameraReader(io.BytesIO(block(7,bytes(28))),replay=True)
        with self.assertRaisesRegex(ValueError,'control'): BlockRecords(reader.exact).next()
        reader=CameraReader(io.BytesIO(block(7,struct.pack('<8I',2,0,10,0,0,0,0,0))),replay=True)
        records=BlockRecords(reader.exact)
        kind,status=records.next()
        self.assertEqual(kind,'camera');self.assertTrue(status['init_error'])
        self.assertEqual(summarize([],records)['decoded_frames'],0)

    def test_stop_occurs_while_no_images_are_available(self):
        class NoData:
            def __init__(self): self.commands=[]
            def write(self,data): self.commands.append(data)
            def flush(self): pass
            def read_chunk(self): return b''
        stream=NoData();reader=CameraReader(stream,duration=1,drain_timeout=1)
        reader.began-=1.5
        reader.check_stop()
        self.assertEqual(stream.commands,[b'S'])
        reader.began-=2
        with self.assertRaises(TimeoutError): reader.exact(8)
        self.assertEqual(stream.commands,[b'S'])

    def test_no_video_diagnostics_separate_clock_data_and_overflow(self):
        def status(flags,ticks=100,data=0,overflow=0):
            reader=CameraReader(io.BytesIO(block(7,struct.pack('<8I',flags,0x5640,270,ticks,0,0,overflow,data))),replay=True)
            return BlockRecords(reader.exact).next()[1]
        first=status(0x49)
        stalled=diagnose_camera([first,first],0)
        self.assertTrue(any('No PCLK counter advance' in text for text in stalled))
        no_href=diagnose_camera([first,status(0x49,ticks=200)],0)
        self.assertTrue(any('no HREF-active bytes' in text for text in no_href))
        overflow=diagnose_camera([first,status(0x49,ticks=200,data=100,overflow=1)],0)
        self.assertTrue(any('overflow increased' in text for text in overflow))
        init_error=diagnose_camera([status(2)],0)
        self.assertTrue(any('register readback' in text for text in init_error))


if __name__=='__main__': unittest.main()

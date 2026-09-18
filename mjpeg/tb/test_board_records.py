"""Checks for the shared telemetry/JPEG record stream."""
import io
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from board_test_receiver import BoardRecords
from mjpeg_receiver import Receiver
from progressive_test import CaptureReader

def telemetry(window,rate,total):
    values=[0x31535046,window,rate,rate,0,total]
    return b''.join(value.to_bytes(4,'little')+bytes([0x80+i]) for i,value in enumerate(values))

def reader(data):
    stream=io.BytesIO(data)
    def exact(n):
        value=stream.read(n)
        if len(value)!=n: raise EOFError('partial record')
        return value
    return BoardRecords(exact)

class RecordsTests(unittest.TestCase):
    def test_batched_packets_with_interleaved_telemetry_and_fragmented_reads(self):
        root=Path(__file__).resolve().parents[1]
        for name,w,h,gray in [('gray_ramp',16,16,True),('color_noise',32,24,False),('color_flat',16,8,False)]:
            with self.subTest(case=name):
                jpeg=(root/'data/board_test'/f'{name}.expected.jpg').read_bytes()
                packets=[]
                for offset in range(0,len(jpeg),16):
                    chunk=jpeg[offset:offset+16]
                    header=0x4d4a1000|len(chunk)|(128 if offset==0 else 0)|(64 if offset+len(chunk)==len(jpeg) else 0)
                    values=[(header,4),(0,4)]+[(int.from_bytes(chunk[i:i+4],'little'),len(chunk[i:i+4])) for i in range(0,len(chunk),4)]
                    wire=b''.join(word.to_bytes(4,'little')+bytes([n|(8 if i==len(values)-1 else 0)]) for i,(word,n) in enumerate(values))
                    if offset==0: wire=wire[:5]+telemetry(1,0,0)+wire[5:]
                    packets.append(wire)
                descriptor=[0x4d4a1400,0,123,0,len(jpeg),h<<16|w,256 if gray else 0]
                packets.append(b''.join(word.to_bytes(4,'little')+bytes([12 if i==6 else 4]) for i,word in enumerate(descriptor)))
                data=b'MJBT'+b''.join(packets)+b'END1\xa0'+telemetry(2,1,1)
                class Fragmented(io.BytesIO):
                    def read(self,n=-1): return super().read(min(n,17) if n>=0 else 17)
                buffered=CaptureReader(Fragmented(data),replay=True)
                records=BoardRecords(buffered.exact);receiver=Receiver();frames=[]
                self.assertEqual(records.next_packet()[0],'start')
                while True:
                    kind,value=records.next_packet()
                    if kind=='end': break
                    if kind=='packet':
                        frame=receiver.packet_words(value)
                        if frame: frames.append(frame)
                    else: self.assertEqual(kind,'fps')
                self.assertEqual(len(frames),1)
                self.assertEqual(frames[0].jpeg,jpeg)
                self.assertEqual((frames[0].width,frames[0].height,frames[0].gray),(w,h,gray))
                self.assertEqual(records.next_packet()[1]['total_compressed'],1)
                self.assertEqual(buffered.offset,len(data))
                self.assertFalse(receiver.frames or receiver.packet)
                legacy=reader(data);legacy_receiver=Receiver();legacy_frames=[]
                while True:
                    kind,value=legacy.next()
                    if kind=='end': break
                    if kind=='word':
                        frame=legacy_receiver.word(*value)
                        if frame: legacy_frames.append(frame)
                self.assertEqual(legacy_frames,frames)

    def test_complete_packet_path_rejects_early_last_and_partial_word(self):
        for words,error in [([(0x4d4a1090,4,False),(0,4,True),(0,4,False)],'last'),
                            ([(0x4d4a1084,4,False),(0,4,False),(0,1,True)],'Partial')]:
            with self.subTest(error=error):
                with self.assertRaisesRegex(ValueError,error): Receiver().packet_words(words)

    def test_idle_telemetry_and_preamble_bytes_inside_payload(self):
        records=reader(telemetry(1,0,0)+b'MJBT'+b'MJBT\x04'+telemetry(2,3,3))
        self.assertEqual(records.next()[0],'fps')
        self.assertEqual(records.next()[0],'start')
        self.assertEqual(records.next(),('word',(int.from_bytes(b'MJBT','little'),4,False)))
        self.assertEqual(records.next()[1]['compressed_fps'],3)

    def test_skipped_window_retains_latest_snapshot(self):
        records=reader(telemetry(1,2,2)+telemetry(4,7,20))
        records.next()
        self.assertEqual(records.next()[1]['window'],4)

    def test_count_mismatch_is_rejected(self):
        records=reader(telemetry(1,2,2)+telemetry(2,3,6))
        records.next()
        with self.assertRaisesRegex(ValueError,'cumulative'): records.next()

    def test_partial_or_out_of_order_snapshot_is_rejected(self):
        with self.assertRaises(EOFError): reader(telemetry(1,0,0)[:-1]).next()
        data=bytearray(telemetry(1,0,0));data[9]=0x83
        with self.assertRaisesRegex(ValueError,'out-of-order'): reader(data).next()

    def test_frame_timings_and_explicit_stream_end(self):
        values=[0x314d4954,42,200,240,300,25,210]
        timing=b''.join(v.to_bytes(4,'little')+bytes([0x90+i]) for i,v in enumerate(values))
        records=reader(b'MJBT'+timing+b'END1\xa0'+b'MJBT')
        self.assertEqual(records.next()[0],'start')
        kind,result=records.next()
        self.assertEqual(kind,'timing')
        self.assertEqual(result['frame_id'],42)
        self.assertEqual(result['total_ticks'],300)
        self.assertEqual(records.next()[0],'end')
        self.assertFalse(records.in_stream)
        self.assertEqual(records.next()[0],'start')

if __name__=='__main__': unittest.main()

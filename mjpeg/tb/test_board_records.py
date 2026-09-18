"""Checks for the shared telemetry/JPEG record stream."""
import io
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from board_test_receiver import BoardRecords

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

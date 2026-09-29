"""Read only the standalone DDR3 acceptance image; reopening resets its test.

The FPGA writes all 4050 reference slots plus high-address probes, then reads
them back against address-dependent patterns. This is not a camera receiver.
"""
import argparse,json,struct,time
from pathlib import Path
from camera_viewer import d2xx_library
from ftdi_fifo import FtdiFifo

FIELDS=('status','address','write_words','read_words','errors','first_bad_address',
        'first_expected','first_observed','test_ticks','calibration_ticks','region')
EXPECTED_WORDS=4051*512+4

def run(serial,library,timeout):
    records=[];buffer=bytearray();deadline=time.monotonic()+timeout
    transport=FtdiFifo(serial,library,synchronous=True)
    try:
        while time.monotonic()<deadline:
            buffer.extend(transport.read_chunk())
            while len(buffer)>=48:
                pos=buffer.find(b'DDRT')
                if pos<0:
                    del buffer[:-3];break
                if pos:del buffer[:pos]
                if len(buffer)<48:break
                values=struct.unpack_from('<11I',buffer,4);del buffer[:48]
                record=dict(zip(FIELDS,values));records.append(record)
                if record['errors'] or record['status']&8:
                    raise RuntimeError('DDR3 read/write failed: '+json.dumps(record))
                if record['status']&2:
                    if record['status']&7!=7 or record['write_words']!=EXPECTED_WORDS or record['read_words']!=EXPECTED_WORDS:
                        raise RuntimeError('Invalid DDR3 completion: '+json.dumps(record))
                    record['bytes_written']=record['write_words']*16
                    record['bytes_read']=record['read_words']*16
                    record['test_seconds']=record['test_ticks']/100_000_000
                    record['calibration_seconds']=record['calibration_ticks']/100_000_000
                    record['aggregate_MB_s']=(record['bytes_written']+record['bytes_read'])/record['test_seconds']/1e6
                    return {'passed':True,'result':record,'status_records':records}
    finally:
        transport.close()
    raise TimeoutError(f'DDR3 did not complete in {timeout}s; latest={records[-1:]}, remainder={len(buffer)}')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial',default='FTB7MA1D');p.add_argument('--library')
    p.add_argument('--timeout',type=float,default=20);p.add_argument('--reopens',type=int,default=3)
    p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    if args.timeout<=0 or args.reopens<1:p.error('timeout and reopens must be positive')
    library=d2xx_library(args.library);sessions=[];args.output.parent.mkdir(parents=True,exist_ok=True)
    try:
        for index in range(args.reopens):
            result=run(args.serial,library,args.timeout);sessions.append(result)
            args.output.write_text(json.dumps({'passed':True,'sessions':sessions},indent=2),encoding='utf-8')
            print(f"DDR3_PASS session={index+1} words={EXPECTED_WORDS} "+json.dumps(result['result']),flush=True)
            time.sleep(.1)
    except Exception as exc:
        args.output.write_text(json.dumps({'passed':False,'sessions':sessions,
                                           'error':f'{type(exc).__name__}: {exc}'},indent=2),encoding='utf-8')
        raise

if __name__=='__main__':main()

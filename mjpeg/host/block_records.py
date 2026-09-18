"""Strict decoder for the board's 1 KB MBLK transport and link counters."""
import struct
from mjpeg_receiver import Frame

class BlockRecords:
    def __init__(self,read_exact,collect_frames=True):
        self.read_exact=read_exact;self.collect_frames=collect_frames
        self.frames={};self.rates=[];self.timings=[];self.links=[];self.in_stream=False
        self.payload_blocks=0;self.payload_bytes=0;self.wire_bytes=0

    def next_packet(self): return self.next()

    def next(self):
        magic,kind,flags,length=struct.unpack('<4sBBH',self.read_exact(8))
        if magic!=b'MBLK' or kind>6: raise ValueError('Invalid block header')
        expected={1:28,2:20,3:24,4:28,5:0,6:0}
        if kind and (flags or length!=expected[kind]): raise ValueError('Invalid control block')
        if kind==0 and (flags&0xe0 or not 4<=length<=1028): raise ValueError('Invalid JPEG block')
        body=self.read_exact(length) if length else b''
        self.wire_bytes+=8+length
        if kind==6:
            if self.in_stream or self.frames: raise ValueError('Unexpected START block')
            self.in_stream=True;return 'start',None
        if kind==5:
            if not self.in_stream or self.frames: raise ValueError('END with incomplete frames')
            self.in_stream=False;return 'end',None
        if kind==0:
            if not self.in_stream: raise ValueError('JPEG outside stream')
            frame_id=struct.unpack_from('<I',body)[0];key=(flags>>3&3,frame_id)
            first,last,abort=bool(flags&1),bool(flags&2),bool(flags&4)
            payload=body[4:]
            if abort and not last or not payload and not abort: raise ValueError('Invalid abort/empty block')
            if first:
                if key in self.frames: raise ValueError('Duplicate frame start')
                self.frames[key]=[bytearray() if self.collect_frames else None,0,False,False]
            if key not in self.frames or self.frames[key][2]: raise ValueError('JPEG frame order')
            frame=self.frames[key];frame[1]+=len(payload)
            if frame[1]>8*1024*1024: raise ValueError('Frame exceeds limit')
            if self.collect_frames: frame[0].extend(payload)
            if last:
                frame[2]=True;frame[3]=abort
                if self.collect_frames and not abort and not (frame[0].startswith(b'\xff\xd8') and frame[0].endswith(b'\xff\xd9')):
                    raise ValueError('JPEG boundary')
            self.payload_blocks+=1;self.payload_bytes+=len(payload)
            return 'chunk',None
        words=struct.unpack('<'+'I'*(length//4),body)
        if kind==1:
            header,frame_id,lo,hi,n,dim,status_word=words
            if header&0xfffffcff!=0x4d4a1400 or status_word>>9 or status_word&0xf0:
                raise ValueError('Invalid descriptor')
            key=(header>>8&3,frame_id)
            if key not in self.frames or not self.frames[key][2]: raise ValueError('Descriptor before frame end')
            payload,actual,_,aborted=self.frames.pop(key);status=status_word&255
            if actual!=n or bool(status&1)!=aborted: raise ValueError('Descriptor length/abort mismatch')
            return 'frame',Frame(key[0],frame_id,lo|hi<<32,dim&65535,dim>>16,bool(status_word&256),status,n,
                bytes(payload) if self.collect_frames and status==0 else None)
        if kind==2:
            rate=dict(zip(('window','input_fps','compressed_fps','failed_fps','total_compressed'),words))
            if self.rates:
                previous=self.rates[-1]
                if rate['window']<=previous['window'] or rate['total_compressed']<previous['total_compressed']:
                    raise ValueError('FPS sequence')
                if rate['window']==previous['window']+1 and rate['total_compressed']-previous['total_compressed']!=rate['compressed_fps']:
                    raise ValueError('FPS cumulative mismatch')
            self.rates.append(rate);return 'fps',rate
        if kind==3:
            timing=dict(zip(('frame_id','feed_ticks','jpeg_ticks','total_ticks','input_wait_ticks','output_wait_ticks'),words))
            if not 0<timing['feed_ticks']<=timing['jpeg_ticks']<=timing['total_ticks'] or timing['input_wait_ticks']>timing['feed_ticks'] or timing['output_wait_ticks']>timing['total_ticks']:
                raise ValueError('Invalid frame timings')
            self.timings.append(timing);return 'timing',timing
        link=dict(zip(('window','cycles','writes','write_busy_cycles','txe_wait_cycles','upstream_empty_cycles','rx_cycles'),words))
        if sum(words[2:])!=link['cycles']: raise ValueError('Link cycle accounting mismatch')
        if self.links and link['window']<=self.links[-1]['window']: raise ValueError('Link window sequence')
        self.links.append(link);return 'link',link

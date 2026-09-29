"""Strict decoder for the board's 1 KB MBLK transport and link counters."""
import struct
from mjpeg_receiver import Frame
from spatial_jpeg import SpatialDecoder, SPATIAL_MAGICS

class BlockRecords:
    def __init__(self,read_exact,collect_frames=True):
        self.read_exact=read_exact;self.collect_frames=collect_frames
        self.frames={};self.rates=[];self.timings=[];self.links=[];self.camera_status=[];self.in_stream=False
        self.preprocess_status=[]
        self.payload_blocks=0;self.payload_bytes=0;self.wire_bytes=0
        self.spatial=SpatialDecoder();self.spatial_stats=None

    def next_packet(self): return self.next()

    def next(self):
        magic,kind,flags,length=struct.unpack('<4sBBH',self.read_exact(8))
        if magic!=b'MBLK' or kind>8: raise ValueError('Invalid block header')
        expected={1:28,2:20,3:24,4:28,5:0,6:0,7:32,8:12}
        if kind and (flags or length!=expected[kind]): raise ValueError('Invalid control block')
        if kind==0 and (flags&0xe0 or not 4<=length<=1028): raise ValueError('Invalid JPEG block')
        body=self.read_exact(length) if length else b''
        self.wire_bytes+=8+length
        if kind==6:
            if self.in_stream or self.frames: raise ValueError('Unexpected START block')
            self.spatial.reset();self.spatial_stats=None
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
                if self.collect_frames and not abort and not (frame[0].startswith(SPATIAL_MAGICS) or
                    frame[0].startswith(b'\xff\xd8') and frame[0].endswith(b'\xff\xd9')):
                    raise ValueError('JPEG boundary')
            self.payload_blocks+=1;self.payload_bytes+=len(payload)
            return 'chunk',None
        words=struct.unpack('<'+'I'*(length//4),body)
        if kind==8:
            requested,active,frames_started=words
            if requested>>24!=1 or requested & 0x00fc0000 or active & 0xfffc0000:
                raise ValueError('Invalid preprocessing status')
            preprocessing=dict(revision=1,mode_requested=requested>>16 & 3,mode=active>>16 & 3,
                binary_threshold_requested=requested & 255,edge_threshold_requested=requested>>8 & 255,
                binary_threshold=active & 255,edge_threshold=active>>8 & 255,frames_started=frames_started)
            if self.rates:
                preprocessing['window']=self.rates[-1]['window']
            self.preprocess_status.append(preprocessing)
            return 'preprocess',preprocessing
        if kind==7:
            camera=dict(zip(('flags','chip_id','config_index','pclk_ticks','received_frames','dropped_frames','overflow_count','dvp_byte_count'),words))
            if camera['flags'] & (1<<12):
                camera['frame_sync_count']=(words[1]>>16)|((words[2]>>16)<<16)
                camera['chip_id'] &= 0xffff
                camera['config_index'] &= 0x1ff
            camera['raw8']=bool(camera['flags'] & (1<<13))
            if camera['flags'] & (1<<15):
                camera['sampling_ready']=bool(camera['flags'] & (1<<14))
            camera['board_controls']=bool(camera['flags'] & (1<<16))
            camera['adaptive_capable']=camera['board_controls'] and bool(words[2] & (1<<9))
            camera['adaptive_enabled']=camera['adaptive_capable'] and bool(camera['flags'] & (1<<7))
            camera['denoise_capable']=camera['board_controls'] and bool(words[2] & (1<<10))
            camera['preprocess_capable']=camera['board_controls'] and bool(words[2] & (1<<12))
            # Bit 11 distinguishes robust YUV processing from the first RGB
            # sigma trial; it is independent of the 9-bit SCCB index/counter.
            camera['denoise_revision']=(2 if words[2] & (1<<11) else 1) if camera['denoise_capable'] else 0
            if camera['denoise_capable']:
                camera['denoise_requested']=camera['flags']>>23 & 255
            camera['threshold_capable']=bool(camera['flags'] & (1<<31))
            if camera['threshold_capable']:
                camera['threshold_requested']=camera['flags']>>23 & 255
            if camera['board_controls']:
                camera['run_requested']=bool(camera['flags'] & (1<<17))
                levels=(60,75,85)
                active=camera['flags']>>18 & 3
                requested=camera['flags']>>20 & 3
                if active>2 or requested>2:
                    raise ValueError('Invalid board quality level')
                camera['quality']=levels[active]
                camera['quality_requested']=levels[requested]
                camera['quality_pending']=bool(camera['flags'] & (1<<22))
            # FPGA sends FPS before the camera snapshot from the same one-
            # second sample. Preserve its window ID; gaps stay visible.
            if self.rates:
                camera['window']=self.rates[-1]['window']
            for bit,name in enumerate(('init_done','init_error','capture_active','tables_ready','codec_busy','config_error','streaming')):
                camera[name]=bool(camera['flags']&(1<<bit))
            for bit,name in enumerate(('light_requested','light_on','light_error','light_busy'),8):
                camera[name]=bool(camera['flags']&(1<<bit))
            self.camera_status.append(camera);return 'camera',camera
        if kind==1:
            header,frame_id,lo,hi,n,dim,status_word=words
            if header&0xfffffcff!=0x4d4a1400 or status_word>>9 or status_word&0xf0:
                raise ValueError('Invalid descriptor')
            key=(header>>8&3,frame_id)
            if key not in self.frames or not self.frames[key][2]: raise ValueError('Descriptor before frame end')
            payload,actual,_,aborted=self.frames.pop(key);status=status_word&255
            if actual!=n or bool(status&1)!=aborted: raise ValueError('Descriptor length/abort mismatch')
            if self.collect_frames and status==0 and payload.startswith(SPATIAL_MAGICS):
                payload=self.spatial.decode(bytes(payload),frame_id)
                self.spatial_stats=dict(frame_id=frame_id,**self.spatial.last_stats)
                if (self.spatial.reference.width,self.spatial.reference.height)!=(dim&65535,dim>>16):
                    self.spatial.reset();raise ValueError('Spatial JPEG descriptor dimensions')
                n=len(payload)
            elif aborted:
                self.spatial.reset()
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

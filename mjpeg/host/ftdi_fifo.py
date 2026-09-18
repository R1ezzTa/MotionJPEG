"""D2XX asynchronous/synchronous FIFO; targets only the board data chip."""
import ctypes as c
import os,time

class FtdiFifo:
    def __init__(self,serial='FTB7MA1D',library=None,synchronous=False):
        self.dll=(c.WinDLL if os.name=='nt' else c.CDLL)(library or ('ftd2xx.dll' if os.name=='nt' else 'libftd2xx.so'))
        self.handle=c.c_void_p(); self.buffer=bytearray(); self.timeout=0.2
        signatures={
            'FT_OpenEx':[c.c_char_p,c.c_uint32,c.POINTER(c.c_void_p)],
            'FT_Close':[c.c_void_p],
            'FT_SetBitMode':[c.c_void_p,c.c_ubyte,c.c_ubyte],
            'FT_SetTimeouts':[c.c_void_p,c.c_uint32,c.c_uint32],
            'FT_SetLatencyTimer':[c.c_void_p,c.c_ubyte],
            'FT_SetUSBParameters':[c.c_void_p,c.c_uint32,c.c_uint32],
            'FT_SetFlowControl':[c.c_void_p,c.c_ushort,c.c_ubyte,c.c_ubyte],
            'FT_Purge':[c.c_void_p,c.c_uint32],
            'FT_GetQueueStatus':[c.c_void_p,c.POINTER(c.c_uint32)],
            'FT_Read':[c.c_void_p,c.c_void_p,c.c_uint32,c.POINTER(c.c_uint32)],
            'FT_Write':[c.c_void_p,c.c_void_p,c.c_uint32,c.POINTER(c.c_uint32)],
            'FT_ReadEE':[c.c_void_p,c.c_uint32,c.POINTER(c.c_ushort)],
            'FT_EEPROM_Read':[c.c_void_p,c.c_void_p,c.c_uint32,c.c_void_p,c.c_void_p,c.c_void_p,c.c_void_p]}
        for name,args in signatures.items():
            func=getattr(self.dll,name);func.argtypes=args;func.restype=c.c_uint32
        self.check(self.dll.FT_OpenEx(serial.encode(),1,c.byref(self.handle)),'FT_OpenEx')
        try:
            # Reset only volatile bit-mode to the EEPROM-selected FIFO interface.
            self.check(self.dll.FT_SetBitMode(self.handle,0,0),'FT_SetBitMode(reset)')
            if synchronous:
                # CLKOUT stops in reset mode. Give the FPGA clock-loss guard
                # time to flush both domains before selecting synchronous mode.
                time.sleep(0.01)
            word=c.c_ushort();self.check(self.dll.FT_ReadEE(self.handle,0,c.byref(word)),'FT_ReadEE')
            self.eeprom_word0=word.value
            # FT_EEPROM_232H layout from the official D2XX guide, 44 bytes.
            eeprom=c.create_string_buffer(44)
            c.cast(eeprom,c.POINTER(c.c_uint32))[0]=8 # FT_DEVICE_232H
            strings=[c.create_string_buffer(64) for _ in range(4)]
            self.check(self.dll.FT_EEPROM_Read(self.handle,eeprom,44,*strings),'FT_EEPROM_Read')
            values=eeprom.raw
            self.eeprom_info={name:values[offset] for name,offset in
                [('IsFifo',35),('IsFifoTar',36),('IsFastSer',37),('IsFT1248',38),('DriverType',40)]}
            self.eeprom_info['serial']=strings[3].value.decode()
            if self.eeprom_info['IsFifo']!=1 or any(values[offset] for offset in (36,37,38)):
                raise ValueError('Board FT232H EEPROM is not configured for FT245 FIFO')
            if synchronous:
                # Volatile interface selection only: never program EEPROM.
                self.check(self.dll.FT_SetBitMode(self.handle,0xff,0x40),'FT_SetBitMode(sync FIFO)')
                time.sleep(0.05)
                self.check(self.dll.FT_SetFlowControl(self.handle,0x0100,0,0),'FT_SetFlowControl')
            self.check(self.dll.FT_SetTimeouts(self.handle,200,2000),'FT_SetTimeouts')
            self.check(self.dll.FT_SetLatencyTimer(self.handle,2),'FT_SetLatencyTimer')
            self.check(self.dll.FT_SetUSBParameters(self.handle,65536,65536),'FT_SetUSBParameters')
            self.eeprom_info['transport']='FT245 synchronous FIFO' if synchronous else 'FT245 asynchronous FIFO'
            self.eeprom_info['link_clock_hz']=60000000 if synchronous else 50000000
            self.reset_input_buffer()
        except Exception:
            self.close();raise

    @staticmethod
    def check(status,operation):
        if status: raise IOError(f'{operation}: D2XX status {status}')

    def reset_input_buffer(self):
        self.buffer.clear();self.check(self.dll.FT_Purge(self.handle,3),'FT_Purge')

    def write(self,data):
        buf=c.create_string_buffer(data);count=c.c_uint32()
        self.check(self.dll.FT_Write(self.handle,buf,len(data),c.byref(count)),'FT_Write')
        if count.value!=len(data): raise IOError('Short FTDI write')
        return count.value

    def flush(self): pass

    def read_chunk(self):
        """Drain available USB bytes in one native call for performance tests."""
        if self.buffer:
            result=bytes(self.buffer);self.buffer.clear();return result
        deadline=time.monotonic()+self.timeout
        while time.monotonic()<deadline:
            queued=c.c_uint32()
            self.check(self.dll.FT_GetQueueStatus(self.handle,c.byref(queued)),'FT_GetQueueStatus')
            if not queued.value: time.sleep(0.001);continue
            size=min(queued.value,65536);buf=c.create_string_buffer(size);count=c.c_uint32()
            self.check(self.dll.FT_Read(self.handle,buf,size,c.byref(count)),'FT_Read')
            return buf.raw[:count.value]
        return b''

    def read(self,n):
        deadline=time.monotonic()+self.timeout
        while len(self.buffer)<n and time.monotonic()<deadline:
            queued=c.c_uint32();self.check(self.dll.FT_GetQueueStatus(self.handle,c.byref(queued)),'FT_GetQueueStatus')
            if not queued.value: time.sleep(0.001);continue
            size=min(queued.value,65536);buf=c.create_string_buffer(size);count=c.c_uint32()
            self.check(self.dll.FT_Read(self.handle,buf,size,c.byref(count)),'FT_Read')
            self.buffer.extend(buf.raw[:count.value])
        result=bytes(self.buffer[:n]);del self.buffer[:n];return result

    def close(self):
        if self.handle.value:
            self.check(self.dll.FT_Close(self.handle),'FT_Close');self.handle=c.c_void_p()

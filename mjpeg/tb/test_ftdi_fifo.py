"""Validate safe interface selection and EEPROM guard without touching USB."""
import ctypes as c
import sys,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from ftdi_fifo import FtdiFifo

class Function:
    def __init__(self,call): self.call=call
    def __call__(self,*args): return self.call(*args)

class FakeD2xx:
    def __init__(self,fifo=True):
        self.events=[]
        for name in ('FT_OpenEx','FT_Close','FT_SetBitMode','FT_SetTimeouts','FT_SetLatencyTimer',
                     'FT_SetUSBParameters','FT_SetFlowControl','FT_Purge','FT_GetQueueStatus','FT_Read','FT_Write','FT_ReadEE','FT_EEPROM_Read'):
            setattr(self,name,Function(lambda *args,n=name:self.call(n,*args)))
        self.fifo=fifo
    def call(self,name,*args):
        self.events.append((name,args[1:] if name=='FT_SetBitMode' else ()))
        if name=='FT_OpenEx': args[2]._obj.value=123
        if name=='FT_ReadEE': args[2]._obj.value=0x11
        if name=='FT_EEPROM_Read':
            args[1][35]=b'\x01' if self.fifo else b'\x00'
            args[1][40]=b'\x01';args[6].value=b'FTB7MA1D'
        return 0

class FifoInitializationTests(unittest.TestCase):
    def open(self,dll,**kwargs):
        loader='ftdi_fifo.c.WinDLL' if sys.platform=='win32' else 'ftdi_fifo.c.CDLL'
        with patch(loader,return_value=dll),patch('ftdi_fifo.time.sleep',side_effect=lambda t:dll.events.append(('sleep',(t,)))):
            return FtdiFifo(**kwargs)
    def test_synchronous_clock_loss_flush_and_no_eeprom_write(self):
        dll=FakeD2xx();stream=self.open(dll,synchronous=True)
        selected=[e for e in dll.events if e[0] in ('FT_SetBitMode','sleep','FT_Purge')]
        self.assertEqual(selected,[('FT_SetBitMode',(0,0)),('sleep',(0.01,)),
                                   ('FT_SetBitMode',(255,64)),('sleep',(0.05,)),('FT_Purge',())])
        self.assertEqual(stream.eeprom_info['link_clock_hz'],60000000)
        self.assertFalse(any('WriteEE' in name or 'Program' in name for name,_ in dll.events))
        stream.close()
    def test_factory_async_regression(self):
        dll=FakeD2xx();stream=self.open(dll)
        self.assertEqual([e for e in dll.events if e[0]=='FT_SetBitMode'],[('FT_SetBitMode',(0,0))])
        self.assertEqual(stream.eeprom_info['link_clock_hz'],50000000);stream.close()
    def test_invalid_eeprom_never_selects_sync(self):
        dll=FakeD2xx(fifo=False)
        with self.assertRaisesRegex(ValueError,'not configured'): self.open(dll,synchronous=True)
        self.assertNotIn(('FT_SetBitMode',(255,64)),dll.events)
        self.assertEqual(dll.events[-1][0],'FT_Close')

if __name__=='__main__': unittest.main()

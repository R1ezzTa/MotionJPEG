"""Board preprocessing protocol, compatibility and reconnect lifecycle."""
import io
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from block_records import BlockRecords
from camera_viewer import PreviewWorker,parse_args,preprocess_command,pixel_threshold_command
from test_camera_viewer import FakeDevice
from test_camera_receiver import block,frame_blocks,jpeg

def camera(capable=True):
    return block(7,struct.pack('<8I',1|(1<<12)|(1<<16),0x56785640,
        0x12340000|283|((1<<12) if capable else 0),0,0,0,0,0))

def status(mode=1,requested=3,binary=128,edge=32):
    return block(8,struct.pack('<3I',(1<<24)|(requested<<16)|(edge<<8)|binary,
        (mode<<16)|(edge<<8)|binary,0x12345678))

class PreprocessTests(unittest.TestCase):
    def test_capability_does_not_corrupt_counters(self):
        for enabled in (False,True):
            kind,s=BlockRecords(io.BytesIO(camera(enabled)).read).next()
            self.assertEqual(kind,'camera');self.assertEqual(s['preprocess_capable'],enabled)
            self.assertEqual(s['config_index'],283);self.assertEqual(s['frame_sync_count'],0x12345678)
            self.assertFalse(s['threshold_capable']);self.assertFalse(s['denoise_capable'])

    def test_status_word_order_and_extremes(self):
        for mode in range(4):
            for threshold in (0,128,255):
                kind,s=BlockRecords(io.BytesIO(status(mode,3-mode,threshold,255-threshold)).read).next()
                self.assertEqual(kind,'preprocess');self.assertEqual(s['mode'],mode)
                self.assertEqual(s['mode_requested'],3-mode);self.assertEqual(s['binary_threshold'],threshold)
                self.assertEqual(s['edge_threshold_requested'],255-threshold)
                self.assertEqual(s['frames_started'],0x12345678)

    def test_invalid_status_reserved_bits_and_length(self):
        for requested,active in ((0,0),(2<<24,0),((1<<24)|(1<<18),0),(1<<24,1<<18)):
            with self.assertRaises(ValueError):
                BlockRecords(io.BytesIO(block(8,struct.pack('<3I',requested,active,0))).read).next()
        with self.assertRaises(ValueError):
            BlockRecords(io.BytesIO(block(8)).read).next()

    def test_command_validation(self):
        self.assertEqual(preprocess_command(3),b'M03\n')
        self.assertEqual(pixel_threshold_command(207),b'BCF\n')
        self.assertEqual(pixel_threshold_command(255,True),b'EFF\n')
        for x in (-1,4,True,0.5,'gray'):
            with self.assertRaises(ValueError):preprocess_command(x)
        for x in (-1,256,True,0.5):
            with self.assertRaises(ValueError):pixel_threshold_command(x)

    def test_cli_replay_and_bounds(self):
        for argv in (['--binary-threshold','256'],['--edge-threshold','-1'],
                     ['--preprocess-mode','bad'],['--capture','old.bin','--preprocess-mode','gray'],
                     ['--capture','old.bin','--binary-threshold','128']):
            with self.assertRaises(SystemExit):parse_args(argv)

    def test_live_request_validates_all_before_send(self):
        worker=PreviewWorker(parse_args([]))
        with self.assertRaises(ValueError):worker.set_preprocess(1,128,32)
        worker.update(preprocess_capable=True)
        for mode,binary,edge in ((4,128,32),(1,256,32),(1,128,-1)):
            with self.assertRaises(ValueError):worker.set_preprocess(mode,binary,edge)
            self.assertTrue(worker.commands.empty())
        worker.set_preprocess(3,128,32)
        self.assertEqual(worker.commands.get_nowait(),b'B80\nE20\nM03\n')
        self.assertEqual(worker.snapshot()[1]['mode_requested'],3)

    def test_configuration_precedes_start(self):
        data=camera()+status()+block(6)+frame_blocks(0,100,jpeg('red'))+block(5)
        device=FakeDevice(data,lambda:worker.stop.set())
        worker=PreviewWorker(parse_args(['--headless','--duration','2','--auto-start',
            '--preprocess-mode','sobel','--binary-threshold','128','--edge-threshold','32']),source_factory=lambda:device)
        worker.run();state=worker.snapshot()[1]
        self.assertIsNone(state['error']);self.assertEqual(state['preprocess']['mode'],1)
        self.assertEqual(device.sent,[b'B80\n',b'E20\n',b'M03\n',b'C',b'l',b'S'])

    def test_old_firmware_rejects_feature_before_start(self):
        device=FakeDevice(camera(False))
        worker=PreviewWorker(parse_args(['--headless','--duration','2','--auto-start','--preprocess-mode','gray']),source_factory=lambda:device)
        worker.run();self.assertIn('requires firmware',worker.snapshot()[1]['error'])
        self.assertNotIn(b'C',device.sent);self.assertNotIn(b'M01\n',device.sent)

    def test_old_capture_without_status_still_decodes(self):
        device=FakeDevice(camera(False)+block(6)+frame_blocks(0,100,jpeg('red'))+block(5),lambda:worker.stop.set())
        worker=PreviewWorker(parse_args(['--headless','--duration','2']),source_factory=lambda:device)
        worker.run();self.assertIsNone(worker.snapshot()[1]['error'])
        self.assertEqual(worker.snapshot()[1]['decoded'],1)
        self.assertIsNone(worker.snapshot()[1]['preprocess'])

    def test_reconnect_restores_configuration_without_start(self):
        old=camera()+status()+block(6)+frame_blocks(8,900,jpeg('red'))+b'BADMAGIC'
        fresh=camera()+status(mode=2,requested=2)+block(6)+frame_blocks(0,100,jpeg('red'))+block(5)
        devices=[FakeDevice(old),FakeDevice(fresh,lambda:worker.stop.set())];opened=iter(devices)
        worker=PreviewWorker(parse_args(['--headless','--duration','3','--preprocess-mode','binary',
            '--binary-threshold','64','--edge-threshold','7']),source_factory=lambda:next(opened))
        worker.run();state=worker.snapshot()[1]
        self.assertIsNone(state['error']);self.assertEqual(state['recoveries'],1)
        self.assertEqual(devices[0].sent,[b'B40\n',b'E07\n',b'M02\n'])
        self.assertEqual(devices[1].sent,[b'B40\n',b'E07\n',b'M02\n',b'l',b'S'])

    def test_capture_cannot_control_board(self):
        worker=PreviewWorker(parse_args(['--capture','old.bin']))
        worker.update(preprocess_capable=True)
        with self.assertRaises(ValueError):worker.set_preprocess(1,128,32)

if __name__=='__main__':unittest.main()

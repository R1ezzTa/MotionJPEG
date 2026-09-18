"""Hardware check: pending 1080p USB data, clock-mode reset, clean G restart."""
import argparse
import ctypes as c
import json
import subprocess
import sys
import time
from pathlib import Path

from ftdi_fifo import FtdiFifo


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library')
    parser.add_argument('--seconds', type=float, default=0.25)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    stream = FtdiFifo(library=args.library, synchronous=True)
    try:
        stream.write(b'F')
        stream.flush()
        time.sleep(args.seconds)  # Deliberately leave the USB input unread.
        queued = c.c_uint32()
        stream.check(stream.dll.FT_GetQueueStatus(stream.handle, c.byref(queued)), 'FT_GetQueueStatus')
        if not queued.value:
            raise ValueError('No pending 1080p data; recovery was not exercised')
        pending_bytes = queued.value
        eeprom_word0 = stream.eeprom_word0
        print(f'PENDING_1080P_USB_BYTES={pending_bytes}', flush=True)
    finally:
        stream.close()
    # Opening the receiver resets bit-mode, stops CLKOUT for 10ms, selects
    # mode 0x40 and purges old USB data. The FPGA guard resets both domains.
    command = [sys.executable, str(Path(__file__).with_name('board_test_receiver.py')),
               '--ftdi', '--blocks', '--sync-fifo', '--sessions', '3',
               '--output', str(args.output)]
    if args.library:
        command += ['--library', args.library]
    subprocess.run(command, check=True)
    frames = json.loads((args.output / 'frames.json').read_text())
    if len(frames) != 27 or [f['frame_id'] for f in frames] != list(range(27)):
        raise ValueError('Restart did not recover frame IDs 0..26')
    if not all(f['reference_equal'] and f['decoded'] for f in frames):
        raise ValueError('Restarted JPEG verification failed')
    result = {'pending_1080p_usb_bytes': pending_bytes, 'pause_seconds': args.seconds,
              'eeprom_word0': eeprom_word0, 'clock_mode_reset': True,
              'first_recovered_frame_id': 0, 'verified_recovered_frames': 27, 'passed': True}
    (args.output / 'recovery_result.json').write_text(json.dumps(result, indent=2))
    print('SYNC_RECOVERY_PASS', flush=True)


if __name__ == '__main__':
    main()

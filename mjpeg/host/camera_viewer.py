"""Live OV5640 preview over USB_SLAVE, or replay an existing MBLK capture.

Run without arguments for the current board. Requires Python 3.10+, Pillow,
Tkinter and, for live viewing, FTDI D2XX. It does not change camera registers
or correct image colors. GUI preview is not a replacement for acceptance tests.
"""
import argparse
import ctypes
import io
import json
import math
import os
import queue
import sys
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path

from PIL import Image
from block_records import BlockRecords


class PreviewStopped(Exception):
    """An intentional stop of offline playback."""


PREPROCESS_MODES=('color','gray','binary','sobel')
PREPROCESS_LABELS=('彩色','灰度','二值化','Sobel 边缘')


def preprocess_command(mode):
    if isinstance(mode,bool) or not isinstance(mode,int) or not 0<=mode<4:
        raise ValueError('Preprocessing mode must be 0 (color), 1 (gray), 2 (binary) or 3 (Sobel)')
    return f'M{mode:02X}\n'.encode('ascii')


def pixel_threshold_command(value, edge=False):
    if isinstance(value,bool) or not isinstance(value,int) or not 0<=value<=255:
        raise ValueError('Pixel/edge threshold must be an integer from 0 to 255')
    return f'{"E" if edge else "B"}{value:02X}\n'.encode('ascii')


def threshold_command(value):
    """Atomic FPGA command; coefficient units, not pixel brightness."""
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 255:
        raise ValueError('Spatial coefficient threshold must be an integer from 0 to 255')
    return f'T{value:02X}\n'.encode('ascii')


def adaptive_command(enabled):
    if not isinstance(enabled, bool):
        raise ValueError('Adaptive mode must be enabled or disabled')
    return b'A1\n' if enabled else b'A0\n'


def denoise_command(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 255:
        raise ValueError('Denoise strength must be an integer from 0 to 255')
    return f'N{value:02X}\n'.encode('ascii')


def d2xx_library(explicit=None):
    if explicit or os.name != 'nt':
        return explicit
    # D2XX may be installed only in the Windows driver store, outside PATH.
    windows = Path(os.environ.get('SystemRoot', 'C:/Windows'))
    candidates = ['ftd2xx.dll', 'ftd2xx64.dll']
    candidates += list((windows / 'System32/DriverStore/FileRepository').glob(
        'ftdibus.inf_*/amd64/ftd2xx64.dll'))
    candidates += list((windows / 'System32/DriverStore/FileRepository').glob(
        'ftdibus.inf_*/i386/ftd2xx.dll'))
    for path in candidates:
        try:
            ctypes.WinDLL(str(path))
            return str(path)
        except OSError:
            pass
    raise OSError('Cannot load FTDI D2XX. Specify --library with the DLL path.')


def decode_frame(frame):
    with Image.open(io.BytesIO(frame.jpeg)) as image:
        if image.format != 'JPEG' or image.size != (frame.width, frame.height):
            raise ValueError('JPEG dimensions differ from the FPGA descriptor')
        return image.convert('RGB')


class PreviewReader:
    def __init__(self, source, stop, commands, replay=False, duration=0,
                 idle_timeout=10, drain_timeout=5):
        self.source = source
        self.stop = stop
        self.commands = commands
        self.replay = replay
        self.duration = duration
        self.idle_timeout = idle_timeout
        self.drain_timeout = drain_timeout
        self.buffer = bytearray()
        self.began = self.last_data = time.monotonic()
        self.stop_time = None
        self.in_stream = False
        self.completed_stream = False

    def check_control(self):
        now = time.monotonic()
        stopping = self.stop.is_set() or (self.duration and now - self.began >= self.duration)
        if self.replay:
            if stopping:
                raise PreviewStopped()
            return
        if stopping and self.stop_time is None:
            self.source.write(b'l')
            self.source.write(b'S')
            self.source.flush()
            self.stop_time = now
            if not self.in_stream:
                raise PreviewStopped()
        while True:
            try:
                command = self.commands.get_nowait()
            except queue.Empty:
                break
            if self.stop_time is None:
                self.source.write(command)
                self.source.flush()
        if self.stop_time is not None:
            if now - self.stop_time > self.drain_timeout:
                raise TimeoutError('No END after stop; USB may have disconnected')
        elif now - self.last_data > self.idle_timeout:
            raise TimeoutError('No USB data; check board power, bitstream and USB_SLAVE')

    def exact(self, count):
        self.check_control()
        while len(self.buffer) < count:
            self.check_control()
            data = self.source.read(65536) if self.replay else self.source.read_chunk()
            if data:
                self.last_data = time.monotonic()
                self.buffer.extend(data)
            elif self.replay:
                if count == 8 and not self.buffer and self.completed_stream:
                    raise PreviewStopped()
                raise EOFError('Capture ended before END or inside an MBLK record')
        value = bytes(self.buffer[:count])
        del self.buffer[:count]
        return value


class PreviewWorker(threading.Thread):
    MAX_CONSECUTIVE_RECOVERIES = 3

    def __init__(self, args, source_factory=None):
        super().__init__(name='camera-usb-reader', daemon=True)
        self.args = args
        self.source_factory = source_factory
        self.stop = threading.Event()
        self.commands = queue.SimpleQueue()
        self.lock = threading.Lock()
        self.latest = None
        self.state = dict(phase='connecting', received=0, failed=0, decoded=0,
                          jpeg_bytes=0, wire_bytes=0, fps=0.0, error=None,
                          camera=None, rate=None, source='capture' if args.capture else 'USB_SLAVE',
                          recoveries=0, last_recovery=None, connection_epoch=0,
                          discarded_partial_frames=0, threshold_capable=None,
                          adaptive_capable=None, adaptive_requested=getattr(args, 'adaptive', None),
                          threshold_requested=getattr(args, 'skip_threshold', None),
                          denoise_capable=None, denoise_requested=getattr(args, 'denoise_strength', None),
                          preprocess_capable=None, preprocess=None,
                          mode_requested=(PREPROCESS_MODES.index(args.preprocess_mode)
                                          if getattr(args,'preprocess_mode',None) is not None else None),
                          binary_threshold_requested=getattr(args,'binary_threshold',None),
                          edge_threshold_requested=getattr(args,'edge_threshold',None))

    def update(self, **values):
        with self.lock:
            self.state.update(values)

    def snapshot(self):
        with self.lock:
            return self.latest, self.state.copy()

    def set_threshold(self, value):
        command = threshold_command(value)
        with self.lock:
            if self.args.capture or self.state['threshold_capable'] is not True:
                raise ValueError('Current firmware does not support adjustable spatial threshold')
            self.state['threshold_requested'] = value
        self.commands.put(command)

    def set_transmission(self, enabled):
        """Change the FPGA run request while keeping the USB reader open."""
        if not isinstance(enabled, bool):
            raise ValueError('Transmission request must be enabled or disabled')
        with self.lock:
            camera = self.state['camera']
            if (self.args.capture or self.state['phase'] not in ('waiting', 'streaming')
                    or self.state['error'] or not camera or not camera['init_done']
                    or camera['init_error'] or camera['config_error']):
                raise ValueError('Live board connection is not ready')
            # C/S update the same run_requested register as KEY0. S drains the
            # current frame and cancels light in hardware; it is not worker.stop.
            self.commands.put(b'C' if enabled else b'S')

    def set_denoise(self, value):
        command = denoise_command(value)
        with self.lock:
            if self.args.capture or self.state['denoise_capable'] is not True:
                raise ValueError('Current firmware does not support adjustable spatial denoise')
            self.state['denoise_requested'] = value
        self.commands.put(command)

    def set_adaptive(self, enabled):
        command = adaptive_command(enabled)
        with self.lock:
            if self.args.capture or self.state['adaptive_capable'] is not True:
                raise ValueError('Current firmware does not support board adaptive mode')
            self.state['adaptive_requested'] = enabled
        self.commands.put(command)

    def set_preprocess(self, mode, binary_threshold, edge_threshold):
        # Validate the whole request before enqueueing any command.
        command=(pixel_threshold_command(binary_threshold)+pixel_threshold_command(edge_threshold,True)
                 +preprocess_command(mode))
        with self.lock:
            if self.args.capture or self.state['preprocess_capable'] is not True:
                raise ValueError('Current firmware does not support board preprocessing')
            self.state.update(mode_requested=mode,binary_threshold_requested=binary_threshold,
                              edge_threshold_requested=edge_threshold)
        self.commands.put(command)

    def open_source(self):
        if self.source_factory:
            return self.source_factory()
        if self.args.capture:
            return self.args.capture.open('rb')
        from ftdi_fifo import FtdiFifo
        return FtdiFifo(serial=self.args.serial,
                        library=d2xx_library(self.args.library), synchronous=True)

    def run(self):
        # Avoid lazy plugin imports interrupting the first live USB frames.
        Image.init()
        source = reader = None
        received = failed = decoded = jpeg_bytes = published = 0
        timestamps = deque(maxlen=60)
        next_id = previous_timestamp = None
        replay_origin = replay_began = None
        error = None
        began = time.monotonic()
        consecutive_recoveries = recoveries = discarded = good_camera_snapshots = wire_base = 0
        threshold_initialized = False
        auto_start_pending = False
        try:
            records = None
            while True:
                if self.stop.is_set() and source is None:
                    raise PreviewStopped()
                try:
                    if source is None:
                        source = self.open_source()
                        reader = PreviewReader(source, self.stop, self.commands,
                                               replay=bool(self.args.capture), duration=self.args.duration,
                                               idle_timeout=self.args.idle_timeout,
                                               drain_timeout=self.args.drain_timeout)
                        reader.began = began  # A reconnect must not restart --duration.
                        records = BlockRecords(reader.exact)
                        good_camera_snapshots = 0
                        next_id = previous_timestamp = None
                        timestamps.clear()
                        replay_origin = replay_began = None
                        with self.lock:
                            self.latest = None
                            self.state.update(connection_epoch=recoveries, camera=None, rate=None, fps=0.0,
                                              threshold_capable=None, adaptive_capable=None, denoise_capable=None, spatial=None,
                                              preprocess_capable=None,preprocess=None)
                            requested = self.state['threshold_requested']
                        threshold_initialized = False
                        auto_start_pending = bool(not self.args.capture and self.args.auto_start and
                                                  (requested is not None or self.state['adaptive_requested'] is not None or
                                                   self.state['denoise_requested'] is not None or
                                                   any(self.state[name] is not None for name in
                                                       ('mode_requested','binary_threshold_requested','edge_threshold_requested'))))
                        if not self.args.capture and self.args.auto_start and not auto_start_pending:
                            source.write(b'C')
                            source.flush()
                            reader.in_stream = True
                        self.update(phase='playing' if self.args.capture else 'waiting')
                    kind, value = records.next()
                    if kind == 'start':
                        reader.in_stream = True
                        reader.completed_stream = False
                        timestamps.clear()
                        replay_origin = replay_began = None
                        self.update(phase='playing' if self.args.capture else 'streaming', fps=0.0)
                    elif kind == 'frame':
                        frame = value
                        if frame.channel != 0 or frame.gray:
                            raise ValueError('Expected a single color camera stream')
                        if next_id is not None and frame.frame_id != next_id:
                            raise ValueError(f'Frame sequence gap: expected {next_id}, got {frame.frame_id}')
                        if previous_timestamp is not None and frame.timestamp <= previous_timestamp:
                            raise ValueError('Camera timestamp did not increase')
                        next_id = (frame.frame_id + 1) & 0xffffffff
                        previous_timestamp = frame.timestamp
                        received += 1
                        if frame.status:
                            failed += 1
                        else:
                            if self.args.headless:
                                decode_frame(frame).close()
                                decoded += 1
                            if self.args.capture and not self.args.headless:
                                if replay_origin is None:
                                    replay_origin = frame.timestamp
                                    replay_began = time.monotonic()
                                due = replay_began + (frame.timestamp - replay_origin) / self.args.core_clock_hz
                                delay = max(0, due - time.monotonic())
                                if self.args.duration:
                                    delay = min(delay, max(0, reader.began + self.args.duration - time.monotonic()))
                                if self.stop.wait(delay):
                                    raise PreviewStopped()
                                reader.check_control()
                            jpeg_bytes += frame.length
                            published += 1
                            timestamps.append(frame.timestamp)
                            fps = ((len(timestamps) - 1) * self.args.core_clock_hz /
                                   (timestamps[-1] - timestamps[0])) if len(timestamps) > 1 else 0.0
                            with self.lock:
                                # A single newest frame bounds memory even if rendering is slow.
                                self.latest = (published, frame)
                                self.state.update(fps=fps, jpeg_bytes=jpeg_bytes)
                        self.update(received=received, failed=failed, decoded=decoded, spatial=records.spatial_stats)
                        if not frame.status:
                            consecutive_recoveries = 0
                    elif kind == 'camera':
                        capable = bool(value.get('threshold_capable', False))
                        self.update(camera=value, threshold_capable=capable,
                                    adaptive_capable=bool(value.get('adaptive_capable', False)),
                                    denoise_capable=bool(value.get('denoise_capable', False)),
                                    preprocess_capable=bool(value.get('preprocess_capable',False)))
                        if value['init_error'] or value['config_error']:
                            raise RuntimeError(f"Camera initialization/configuration error at index {value['config_index']}")
                        if not self.args.capture and not threshold_initialized:
                            with self.lock:
                                requested = self.state['threshold_requested']
                            if requested is not None:
                                if not capable:
                                    raise RuntimeError('--skip-threshold requires firmware with adjustable spatial threshold support')
                                self.commands.put(threshold_command(requested))
                            adaptive = self.state['adaptive_requested']
                            if adaptive is not None:
                                if not value.get('adaptive_capable', False):
                                    raise RuntimeError('--adaptive requires firmware with board adaptive mode support')
                                self.commands.put(adaptive_command(adaptive))
                            denoise = self.state['denoise_requested']
                            if denoise is not None:
                                if not value.get('denoise_capable', False):
                                    raise RuntimeError('--denoise-strength requires firmware with spatial denoise support')
                                self.commands.put(denoise_command(denoise))
                            for name,encode in (('binary_threshold_requested',pixel_threshold_command),
                                                ('edge_threshold_requested',lambda v:pixel_threshold_command(v,True)),
                                                ('mode_requested',preprocess_command)):
                                setting=self.state[name]
                                if setting is not None:
                                    if not value.get('preprocess_capable',False):
                                        raise RuntimeError('--preprocess-mode/threshold requires firmware with preprocessing support')
                                    self.commands.put(encode(setting))
                            if auto_start_pending:
                                self.commands.put(b'C')
                                reader.in_stream = True
                                auto_start_pending = False
                            reader.check_control()
                            threshold_initialized = True
                        if not value['streaming'] and value['init_done']:
                            good_camera_snapshots += 1
                            if good_camera_snapshots >= 2:
                                consecutive_recoveries = 0
                    elif kind == 'preprocess':
                        self.update(preprocess=value)
                    elif kind == 'fps':
                        self.update(rate=value)
                    elif kind == 'end':
                        reader.in_stream = False
                        reader.completed_stream = True
                        if reader.stop_time is not None:
                            self.update(phase='finished')
                            break
                        self.update(phase='waiting', fps=0.0)
                    if kind != 'chunk':
                        self.update(wire_bytes=wire_base + records.wire_bytes)
                    # Parser history is needed only for the previous telemetry window.
                    for history in (records.rates, records.timings, records.links, records.camera_status,records.preprocess_status):
                        if len(history) > 2:
                            del history[:-2]
                except (ValueError, OSError, EOFError, TimeoutError) as exc:
                    if (self.args.capture or self.stop.is_set() or
                            (reader is not None and reader.stop_time is not None) or
                            consecutive_recoveries >= self.MAX_CONSECUTIVE_RECOVERIES):
                        raise
                    consecutive_recoveries += 1
                    recoveries += 1
                    discarded += len(records.frames) if records is not None else 0
                    wire_base += records.wire_bytes if records is not None else 0
                    self.update(phase='reconnecting', recoveries=recoveries,
                                last_recovery=f'{type(exc).__name__}: {exc}',
                                discarded_partial_frames=discarded, fps=0.0)
                    if source is not None:
                        try:
                            source.close()
                        except OSError:
                            pass
                    source = reader = records = None
                    # Reopening D2XX purges FTDI bytes and briefly stops CLKOUT,
                    # letting the existing FPGA clock guard flush its FIFOs.
                    # Do not issue C/S/L here: board keys retain ownership.
                    if self.stop.wait(0.2):
                        raise PreviewStopped()
                    continue
        except PreviewStopped:
            self.update(phase='finished')
        except Exception as exc:
            error = f'{type(exc).__name__}: {exc}'
        finally:
            if source is not None:
                if not self.args.capture and (reader is None or reader.stop_time is None):
                    try:
                        source.write(b'l')
                        source.write(b'S')
                        source.flush()
                    except Exception as exc:
                        error = error or f'Stop failed: {exc}'
                try:
                    source.close()
                except Exception as exc:
                    error = error or f'Close failed: {exc}'
            if error:
                self.update(phase='error', error=error)


class PreviewPreparation(threading.Thread):
    """Decode/resize away from Tk; retain one waiting job and one result."""

    def __init__(self, decoder=decode_frame):
        super().__init__(name='camera-preview-preparation', daemon=True)
        self.decoder = decoder
        self.condition = threading.Condition()
        self.pending = self.latest = None
        self.generation = 0
        self.stopping = False
        self.error = None
        self.prepared = self.replaced = 0
        self.elapsed = 0.0

    def submit(self, number, frame, bounds, epoch):
        with self.condition:
            if self.stopping:
                return
            if self.pending is not None:
                self.replaced += 1
            self.pending = (number, frame, bounds, epoch, self.generation)
            self.condition.notify()

    def take(self):
        with self.condition:
            value, self.latest = self.latest, None
            return value

    def clear(self):
        with self.condition:
            self.generation += 1
            self.pending = None
            if self.latest is not None:
                self.latest[-1].close()
                self.latest = None

    def close(self):
        with self.condition:
            self.stopping = True
            self.generation += 1
            self.pending = None
            if self.latest is not None:
                self.latest[-1].close()
                self.latest = None
            self.condition.notify()

    def run(self):
        while True:
            with self.condition:
                self.condition.wait_for(lambda: self.stopping or self.pending is not None)
                if self.stopping:
                    return
                job, self.pending = self.pending, None
            number, frame, bounds, epoch, generation = job
            began = time.monotonic()
            image = None
            try:
                image = self.decoder(frame)
                if bounds is not None:
                    image.thumbnail(bounds, Image.Resampling.BILINEAR)
                with self.condition:
                    if self.stopping or generation != self.generation:
                        image.close()
                        if self.stopping:
                            return
                        continue
                    if self.latest is not None:
                        self.latest[-1].close()
                    self.latest = (number, frame, bounds, epoch, image)
                    self.prepared += 1
                    self.elapsed += time.monotonic() - began
            except Exception as exc:
                if image is not None:
                    image.close()
                with self.condition:
                    if self.stopping:
                        return
                    if generation != self.generation:
                        continue
                    self.error = f'{type(exc).__name__}: {exc}'
                    self.stopping = True
                    self.condition.notify()
                return


class PreviewWindow:
    def __init__(self, worker, args):
        import tkinter as tk
        from tkinter import ttk
        from PIL import ImageTk
        self.tk, self.ImageTk = tk, ImageTk
        self.worker, self.args = worker, args
        self.root = tk.Tk()
        self.root.title('OV5640 · FPGA MJPEG 实时预览')
        self.root.geometry('1120x800')
        self.root.minsize(640, 460)
        self.root.protocol('WM_DELETE_WINDOW', self.close)
        self.root.report_callback_exception = self.callback_error
        self.paused = self.closing = self.full_size = False
        self.displayed = self.skipped = self.last_number = 0
        self.current = self.photo = None
        self.photo_size = None
        self.last_submitted = None
        Image.init()
        self.preparation = PreviewPreparation()
        self.connection_epoch = 0
        self.shown_recoveries = 0
        self.tick_id = None
        self.dirty = True
        self.last_bandwidth_time = time.monotonic()
        self.last_bytes = 0
        self.last_wire_bytes = 0
        self.last_displayed = 0
        self.display_fps = 0.0
        self.bandwidth = 0.0
        self.wire_bandwidth = 0.0
        transmission_bar = ttk.Frame(self.root, padding=(8, 8, 8, 0))
        transmission_bar.pack(fill='x')
        ttk.Label(transmission_bar, text='板卡图像传输：').pack(side='left')
        self.start_button = ttk.Button(transmission_bar, text='开启传输',
                                       command=lambda: self.set_transmission(True), state='disabled')
        self.start_button.pack(side='left', padx=4)
        self.stop_button = ttk.Button(transmission_bar, text='停止传输',
                                      command=lambda: self.set_transmission(False), state='disabled')
        self.stop_button.pack(side='left', padx=4)
        self.transmission = tk.StringVar(value='等待板卡状态…')
        ttk.Label(transmission_bar, textvariable=self.transmission).pack(side='left', padx=8)
        toolbar = ttk.Frame(self.root, padding=8)
        toolbar.pack(fill='x')
        self.pause_button = ttk.Button(toolbar, text='暂停画面 [空格]', command=self.pause)
        self.pause_button.pack(side='left')
        ttk.Button(toolbar, text='保存原始 JPEG [S]', command=self.save).pack(side='left', padx=6)
        self.scale_button = ttk.Button(toolbar, text='切换 1:1 查看', command=self.scale)
        self.scale_button.pack(side='left')
        ttk.Button(toolbar, text='补光 2 秒 [L]', command=self.light,
                   state='disabled' if args.capture else 'normal').pack(side='left', padx=6)
        ttk.Button(toolbar, text='关闭 [Esc]', command=self.close).pack(side='right')
        denoise_bar = ttk.Frame(self.root, padding=(8, 0, 8, 6))
        denoise_bar.pack(fill='x')
        ttk.Label(denoise_bar, text='板内空间降噪强度（0=关闭）：').pack(side='left')
        self.denoise = tk.StringVar(value=str(getattr(args, 'denoise_strength', None) or 0))
        self.denoise_initialized = getattr(args, 'denoise_strength', None) is not None
        self.denoise_entry = ttk.Spinbox(denoise_bar, from_=0, to=255, width=6,
                                        textvariable=self.denoise, state='disabled')
        self.denoise_entry.pack(side='left', padx=4)
        self.denoise_entry.bind('<Return>', lambda event: self.apply_denoise())
        self.denoise_apply = ttk.Button(denoise_bar, text='应用', command=self.apply_denoise, state='disabled')
        self.denoise_apply.pack(side='left')
        self.denoise_presets = []
        for label, strength in (('关闭', 0), ('弱 8', 8), ('中 16', 16), ('强 32', 32)):
            button = ttk.Button(denoise_bar, text=label, state='disabled',
                                command=lambda value=strength: self.preset_denoise(value))
            button.pack(side='left', padx=3)
            self.denoise_presets.append(button)
        preprocess_bar=ttk.Frame(self.root,padding=(8,4))
        preprocess_bar.pack(fill='x')
        ttk.Label(preprocess_bar,text='板内预处理：').pack(side='left')
        self.preprocess_mode=PREPROCESS_MODES.index(args.preprocess_mode) if getattr(args,'preprocess_mode',None) else 0
        self.preprocess_initialized=False
        self.preprocess_buttons=[]
        for mode,label in enumerate(PREPROCESS_LABELS):
            button=ttk.Button(preprocess_bar,text=label,state='disabled',
                              command=lambda mode=mode:self.apply_preprocess(mode))
            button.pack(side='left',padx=2)
            self.preprocess_buttons.append(button)
        self.binary_threshold=tk.StringVar(value=str(getattr(args,'binary_threshold',None) if
                                                    getattr(args,'binary_threshold',None) is not None else 128))
        self.edge_threshold=tk.StringVar(value=str(getattr(args,'edge_threshold',None) if
                                                  getattr(args,'edge_threshold',None) is not None else 32))
        self.preprocess_entries=[]
        for label,variable in (('亮度阈值',self.binary_threshold),('边缘阈值',self.edge_threshold)):
            ttk.Label(preprocess_bar,text=label).pack(side='left',padx=(6,0))
            entry=ttk.Spinbox(preprocess_bar,from_=0,to=255,width=5,textvariable=variable,state='disabled')
            entry.pack(side='left',padx=2)
            entry.bind('<Return>',lambda event:self.apply_preprocess())
            self.preprocess_entries.append(entry)
        self.preprocess_apply=ttk.Button(preprocess_bar,text='应用阈值',state='disabled',command=self.apply_preprocess)
        self.preprocess_apply.pack(side='left',padx=3)
        area = ttk.Frame(self.root)
        area.pack(fill='both', expand=True)
        area.rowconfigure(0, weight=1)
        area.columnconfigure(0, weight=1)
        self.canvas = tk.Canvas(area, background='#17191d', highlightthickness=0)
        self.canvas.grid(row=0, column=0, sticky='nsew')
        sx = ttk.Scrollbar(area, orient='horizontal', command=self.canvas.xview)
        sy = ttk.Scrollbar(area, orient='vertical', command=self.canvas.yview)
        sx.grid(row=1, column=0, sticky='ew')
        sy.grid(row=0, column=1, sticky='ns')
        self.canvas.configure(xscrollcommand=sx.set, yscrollcommand=sy.set)
        self.canvas.bind('<Configure>', lambda event: setattr(self, 'dirty', True))
        self.image_id = self.canvas.create_image(0, 0, anchor='nw')
        self.info = tk.StringVar(value='正在连接…')
        self.telemetry = tk.StringVar()
        self.notice = tk.StringVar(value='PC 按钮或 KEY0 启停传输，KEY1 切画质，KEY2 补光，KEY3 停止；暂停仅冻结显示。')
        self.labels = []
        for variable in (self.info, self.telemetry, self.notice):
            label = ttk.Label(self.root, textvariable=variable, padding=(8, 4), wraplength=1080)
            label.pack(fill='x')
            self.labels.append(label)
        self.root.bind('<Configure>', self.resize_labels)
        self.root.bind('<space>', lambda event: self.pause())
        self.root.bind('<s>', lambda event: self.save())
        self.root.bind('<S>', lambda event: self.save())
        self.root.bind('<l>', lambda event: self.light())
        self.root.bind('<L>', lambda event: self.light())
        self.root.bind('<Escape>', lambda event: self.close())
        self.preparation.start()
        self.schedule(16)

    def schedule(self, delay):
        if self.tick_id is not None:
            self.root.after_cancel(self.tick_id)
        self.tick_id = self.root.after(delay, self.tick)

    def resize_labels(self, event):
        if event.widget is self.root:
            for label in self.labels:
                label.configure(wraplength=max(200, event.width - 20))

    def pause(self):
        self.paused = not self.paused
        self.pause_button.configure(text='继续画面 [空格]' if self.paused else '暂停画面 [空格]')

    def scale(self):
        self.full_size = not self.full_size
        self.scale_button.configure(text='切换适应窗口' if self.full_size else '切换 1:1 查看')
        self.canvas.xview_moveto(0)
        self.canvas.yview_moveto(0)
        self.dirty = True

    def light(self):
        if not self.args.capture and self.worker.is_alive() and not self.closing:
            self.worker.commands.put(b'L')
            self.notice.set('已请求补光；FPGA 限制约 2 秒后自动关闭。')

    def set_transmission(self, enabled):
        if not self.worker.is_alive() or self.closing:
            return
        try:
            self.worker.set_transmission(enabled)
            self.notice.set('已请求开启传输；等待板卡状态确认。' if enabled else
                            '已请求停止传输；板卡排完当前帧并关灯，窗口保持连接。')
        except ValueError as exc:
            self.notice.set(f'传输控制未发送：{exc}')

    def update_transmission(self, state):
        camera = state['camera']
        ready = (not self.args.capture and self.worker.is_alive() and not state['error']
                 and state['phase'] in ('waiting', 'streaming') and camera
                 and camera['init_done'] and not camera['init_error'] and not camera['config_error'])
        for control in (self.start_button, self.stop_button):
            control.configure(state='normal' if ready else 'disabled')
        if self.args.capture:
            label = '抓包回放（不连接板卡）'
        elif state['error']:
            label = '连接/数据错误'
        elif not ready:
            label = '连接中，等待初始化完成…' if self.worker.is_alive() else '连接已结束'
        elif camera.get('board_controls'):
            if camera['streaming']:
                label = '板卡报告：已开启' if camera['run_requested'] else '板卡报告：正在停止'
            else:
                label = '板卡报告：正在开启' if camera['run_requested'] else '板卡报告：已停止'
        else:
            label = '已开启' if state['phase'] == 'streaming' else '已停止'
        self.transmission.set(label)

    def apply_denoise(self):
        if not self.worker.is_alive() or self.closing:
            return
        try:
            value = int(self.denoise.get())
            self.worker.set_denoise(value)
            self.notice.set(f'已请求板内空间降噪强度 {value}；在后续完整帧生效，0 表示关闭。')
        except ValueError as exc:
            self.notice.set(f'降噪设置未发送：{exc}')

    def preset_denoise(self, value):
        self.denoise.set(str(value))
        self.apply_denoise()

    def apply_preprocess(self,mode=None):
        if not self.worker.is_alive() or self.closing:
            return
        try:
            chosen=self.preprocess_mode if mode is None else mode
            self.worker.set_preprocess(chosen,int(self.binary_threshold.get()),int(self.edge_threshold.get()))
            self.preprocess_mode=chosen
            self.notice.set(f'已请求板内{PREPROCESS_LABELS[chosen]}；阈值范围 0–255，等待完整帧及板卡回报。')
        except ValueError as exc:
            self.notice.set(f'预处理设置未发送：{exc}')

    def update_preprocess(self,state):
        ready=(not self.args.capture and self.worker.is_alive() and not state['error']
               and state.get('preprocess_capable') is True and state.get('preprocess') is not None)
        for control in (*self.preprocess_buttons,*self.preprocess_entries,self.preprocess_apply):
            control.configure(state='normal' if ready else 'disabled')
        status=state.get('preprocess')
        if status is None:
            return '  |  预处理状态待回报' if state.get('preprocess_capable') else ''
        if not self.preprocess_initialized:
            if state['mode_requested'] is None:self.preprocess_mode=status['mode_requested']
            if state['binary_threshold_requested'] is None:self.binary_threshold.set(str(status['binary_threshold_requested']))
            if state['edge_threshold_requested'] is None:self.edge_threshold.set(str(status['edge_threshold_requested']))
            self.preprocess_initialized=True
        text=f"  |  板内{PREPROCESS_LABELS[status['mode']]}（亮度 {status['binary_threshold']} / 边缘 {status['edge_threshold']}）"
        actual=(status['mode'],status['binary_threshold'],status['edge_threshold'])
        requested=tuple(state[name] if state[name] is not None else status[name] for name in
                        ('mode_requested','binary_threshold_requested','edge_threshold_requested'))
        if requested!=actual:
            text+=f' → {PREPROCESS_LABELS[requested[0]]} / {requested[1]} / {requested[2]}（等待生效）'
        return text

    def save(self):
        if self.current is None:
            self.notice.set('尚无可保存的画面。')
            return
        try:
            self.args.save_dir.mkdir(parents=True, exist_ok=True)
            path = self.args.save_dir / ('camera0_frame' + str(self.current.frame_id) + '_' +
                                        datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.jpg')
            path.write_bytes(self.current.jpeg)
            self.notice.set(f'已保存原始 JPEG：{path.resolve()}')
        except OSError as exc:
            self.notice.set(f'保存失败：{exc}')

    def preview_bounds(self):
        return None if self.full_size else (max(1, self.canvas.winfo_width()),
                                           max(1, self.canvas.winfo_height()))

    def render(self, image):
        # All Tk calls stay on the window thread. JPEG decoding and resizing
        # have already finished; reuse the Tk image allocation at equal size.
        if self.photo is not None and self.photo_size == image.size:
            self.photo.paste(image)
        else:
            self.photo = self.ImageTk.PhotoImage(image, master=self.root)
            self.photo_size = image.size
            self.canvas.itemconfigure(self.image_id, image=self.photo)
        self.canvas.configure(scrollregion=(0, 0, image.width, image.height))

    def tick(self):
        tick_began = time.monotonic()
        self.tick_id = None
        newest, state = self.worker.snapshot()
        if self.closing:
            self.start_button.configure(state='disabled')
            self.stop_button.configure(state='disabled')
            if not self.worker.is_alive() and not self.preparation.is_alive():
                self.root.destroy()
                return
            self.info.set('正在停止摄像头并排空当前帧…')
            self.schedule(50)
            return
        if state['connection_epoch'] != self.connection_epoch:
            self.connection_epoch = state['connection_epoch']
            self.preprocess_initialized=False
            self.current = self.photo = None
            self.photo_size = self.last_submitted = None
            self.preparation.clear()
            self.canvas.itemconfigure(self.image_id, image='')
        bounds = self.preview_bounds()
        if newest is not None and not self.paused:
            number, frame = newest
            request = (number, bounds, self.connection_epoch)
            if request != self.last_submitted or self.dirty:
                self.preparation.submit(number, frame, bounds, self.connection_epoch)
                self.last_submitted = request
                self.dirty = False
        elif self.current is not None and self.dirty:
            # Resizing a paused image also uses the background preparation path.
            self.preparation.submit(self.last_number, self.current, bounds, self.connection_epoch)
            self.dirty = False
        prepared = self.preparation.take()
        if prepared is not None:
            number, frame, target, epoch, image = prepared
            try:
                if (epoch == self.connection_epoch and target == bounds and number >= self.last_number
                        and (not self.paused or number == self.last_number)):
                    if number > self.last_number:
                        self.skipped += max(0, number - self.last_number - 1)
                        self.displayed += 1
                    self.current, self.last_number = frame, number
                    self.render(image)
            finally:
                image.close()
        if self.preparation.error:
            self.worker.update(error=self.preparation.error, phase='error')
            self.close()
            return
        now = time.monotonic()
        if now - self.last_bandwidth_time >= 1:
            self.bandwidth = (state['jpeg_bytes'] - self.last_bytes) / (now - self.last_bandwidth_time) / 1e6
            self.wire_bandwidth = (state['wire_bytes'] - self.last_wire_bytes) / (now - self.last_bandwidth_time) / 1e6
            self.display_fps = (self.displayed - self.last_displayed) / (now - self.last_bandwidth_time)
            self.last_displayed = self.displayed
            self.last_bandwidth_time, self.last_bytes = now, state['jpeg_bytes']
            self.last_wire_bytes = state['wire_bytes']
        frame_info = (f'{self.current.width}×{self.current.height}  帧号 {self.current.frame_id}'
                      f'  JPEG {self.current.length / 1024:.1f} KiB') if self.current else '等待图像'
        label = {'connecting': '连接中', 'streaming': '实时预览', 'playing': '抓包回放',
                 'reconnecting': '数据流中断，正在重新连接',
                 'waiting': '等待开启传输（PC 按钮或 KEY0）', 'finished': '已结束', 'error': '连接/数据错误'}[state['phase']]
        self.info.set(f"{label}  |  {frame_info}  |  JPEG {state['fps']:.2f} fps"
                      f"  |  显示 {self.display_fps:.1f} fps"
                      f"  |  传输 {self.wire_bandwidth:.2f} MB/s / JPEG {self.bandwidth:.2f} MB/s"
                      f"  |  收到 {state['received']} 帧"
                      f"  |  预览跳过 {self.skipped} 帧  |  编码失败 {state['failed']}")
        camera, rate = state['camera'], state['rate']
        self.update_transmission(state)
        text = f"板内输入/压缩/失败 fps：{rate['input_fps']}/{rate['compressed_fps']}/{rate['failed_fps']}" if rate else '等待板内状态'
        if camera:
            text += (f"  |  {'RAW8' if camera['raw8'] else 'YUV422'}"
                     f"  初始化 {'完成' if camera['init_done'] else '进行中'}"
                     f"  累计准入跳帧/丢帧 {camera['dropped_frames']}"
                     f"  溢出 {camera['overflow_count']}"
                     f"  补光 {'亮' if camera['light_on'] else '灭'}")
            if camera.get('board_controls'):
                text += f"  |  画质 Q{camera['quality']}"
                if camera['quality_pending']:
                    text += f" → Q{camera['quality_requested']}（等待帧结束）"
        spatial=state.get('spatial')
        if spatial:
            text += (f"  |  空间复用 {spatial['reused']}/{spatial['groups']}"
                     f"  负载 {spatial['transport_bytes']/1024:.1f} KiB")
            if 'threshold' in spatial:
                text += f"  |  {'本帧自适应上限' if spatial.get('adaptive') else '本帧系数阈值'} {spatial['threshold']}"
        requested = state.get('denoise_requested')
        if camera and camera.get('denoise_capable'):
            board_requested = camera['denoise_requested']
            if not self.denoise_initialized:
                self.denoise.set(str(board_requested))
                self.denoise_initialized = True
            name = '稳健降噪 v2' if camera.get('denoise_revision') == 2 else '板内降噪 v1'
            text += f"  |  {name} 请求强度 {board_requested}"
            if requested is not None and requested != board_requested:
                text += f" → {requested}（等待状态确认）"
        control_state = ('normal' if not self.args.capture and state.get('denoise_capable') is True
                         and self.worker.is_alive() else 'disabled')
        for control in (self.denoise_entry, self.denoise_apply, *self.denoise_presets):
            control.configure(state=control_state)
        text+=self.update_preprocess(state)
        self.telemetry.set(text)
        if state['error']:
            self.notice.set(state['error'])
        elif state['phase'] == 'reconnecting':
            self.notice.set('正在清理中断的数据并重新连接；恢复后可用 PC 按钮或 KEY0 开启。')
        elif state['recoveries'] > self.shown_recoveries:
            self.shown_recoveries = state['recoveries']
            self.notice.set(f"数据流已恢复 {state['recoveries']} 次；可用 PC 按钮或 KEY0 开启。")
        if self.args.duration and not self.worker.is_alive():
            self.root.destroy()
            return
        # Poll at 60 Hz so preparation completion does not wait a full sensor
        # period. Only new completed frames cause a Tk image update.
        self.schedule(max(1, round(1000 / 60 - (time.monotonic() - tick_began) * 1000)))

    def callback_error(self, error_type, error, traceback):
        self.worker.update(error=f'{error_type.__name__}: {error}', phase='error')
        self.close()

    def close(self):
        self.closing = True
        self.worker.stop.set()
        self.preparation.close()
        # Also covers exceptions raised during a render before tick reschedules.
        self.schedule(50)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, help='Replay usb_capture.bin instead of opening USB')
    parser.add_argument('--serial', default='FTB7MA1D', help='USB_SLAVE FT232H serial number')
    parser.add_argument('--library', help='D2XX DLL/SO path; Windows driver store is searched automatically')
    parser.add_argument('--duration', type=float, default=0, help='Auto-close after N seconds; 0 means continuous')
    parser.add_argument('--core-clock-hz', type=int, default=100_000_000)
    parser.add_argument('--idle-timeout', type=float, default=10)
    parser.add_argument('--drain-timeout', type=float, default=5)
    parser.add_argument('--save-dir', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'reports/ov5640/preview_snapshots')
    parser.add_argument('--headless', action='store_true', help='Receive and independently decode every frame without GUI')
    parser.add_argument('--auto-start', action='store_true', help='Send USB START automatically; default waits for PC button or board KEY0')
    parser.add_argument('--skip-threshold', type=int, default=None,
                        help=argparse.SUPPRESS)
    parser.add_argument('--adaptive', action=argparse.BooleanOptionalAction, default=None,
                        help=argparse.SUPPRESS)
    parser.add_argument('--denoise-strength', type=int, default=None,
                        help='FPGA current-frame spatial denoise strength 0..255; 0 disables filtering. Omit to retain board setting')
    parser.add_argument('--preprocess-mode',choices=PREPROCESS_MODES,default=None,
                        help='Board preprocessing; omit to retain board setting')
    parser.add_argument('--binary-threshold',type=int,default=None,help='Board brightness threshold 0..255 (reset 128)')
    parser.add_argument('--edge-threshold',type=int,default=None,help='Board normalized Sobel threshold 0..255 (reset 32)')
    args = parser.parse_args(argv)
    if not math.isfinite(args.duration) or args.duration < 0 or args.core_clock_hz <= 0:
        parser.error('Duration must be finite and nonnegative; core clock must be positive')
    if any(not math.isfinite(x) or x <= 0 for x in (args.idle_timeout, args.drain_timeout)):
        parser.error('Timeouts must be finite and positive')
    if args.headless and not args.capture and not args.duration:
        parser.error('Live --headless mode requires --duration')
    if args.skip_threshold is not None and not 0 <= args.skip_threshold <= 255:
        parser.error('--skip-threshold must be from 0 to 255')
    if args.capture and args.skip_threshold is not None:
        parser.error('--skip-threshold cannot alter capture replay')
    if args.capture and args.adaptive is not None:
        parser.error('--adaptive cannot alter capture replay')
    if args.denoise_strength is not None and not 0 <= args.denoise_strength <= 255:
        parser.error('--denoise-strength must be from 0 to 255')
    if args.capture and args.denoise_strength is not None:
        parser.error('--denoise-strength cannot alter capture replay')
    for name in ('binary_threshold','edge_threshold'):
        setting=getattr(args,name)
        if setting is not None and not 0<=setting<=255:
            parser.error('--'+name.replace('_','-')+' must be from 0 to 255')
    if args.capture and any(getattr(args,name) is not None for name in
                            ('preprocess_mode','binary_threshold','edge_threshold')):
        parser.error('Preprocessing controls cannot alter capture replay')
    return args


def main(argv=None):
    args = parse_args(argv)
    worker = PreviewWorker(args)
    window = None
    if not args.headless:
        # Initialize Tk before starting USB so a missing desktop leaves no stream open.
        window = PreviewWindow(worker, args)
    worker.start()
    try:
        if window:
            window.root.mainloop()
        else:
            while worker.is_alive():
                worker.join(0.2)
    except KeyboardInterrupt:
        worker.stop.set()
    finally:
        worker.stop.set()
        worker.join(args.drain_timeout + 5)
        if window:
            window.preparation.close()
            window.preparation.join(args.drain_timeout)
    _, state = worker.snapshot()
    if worker.is_alive():
        state['error'] = state['error'] or 'USB worker did not stop within the deadline'
    if window:
        state.update(displayed=window.displayed, decoded=window.displayed,
                     preview_skipped=window.skipped,
                     preview_prepared=window.preparation.prepared,
                     preparation_mean_ms=(window.preparation.elapsed * 1000 / window.preparation.prepared
                                          if window.preparation.prepared else 0))
    print(json.dumps(state, ensure_ascii=True, indent=2))
    return 1 if state['error'] else 0


if __name__ == '__main__':
    raise SystemExit(main())

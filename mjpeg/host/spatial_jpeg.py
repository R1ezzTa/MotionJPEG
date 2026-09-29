"""Exact reuse of independently coded JPEG restart intervals at fixed MCU positions.

SPJ1 is a transport representation, never a standalone JPEG. The decoder restores
the original JPEG bytes before handing them to an ordinary JPEG decoder.
"""
import struct
from dataclasses import dataclass

MAGIC = b'SPJ1'
THRESHOLD_MAGIC = b'SPJ2'
SPATIAL_MAGICS = (MAGIC, THRESHOLD_MAGIC)
NONE = 0xffffffff
MAX_FRAME = 8 * 1024 * 1024


@dataclass(frozen=True)
class SpatialJPEG:
    header: bytes
    groups: tuple
    width: int
    height: int
    interval: int
    mcu_width: int

    def rectangle(self, index):
        columns = self.width // self.mcu_width
        first = index * self.interval
        return ((first % columns) * self.mcu_width, (first // columns) * 8,
                self.interval * self.mcu_width, 8)


def split_jpeg(jpeg):
    if not jpeg.startswith(b'\xff\xd8') or len(jpeg) > MAX_FRAME:
        raise ValueError('Spatial JPEG boundary/size')
    p = 2
    width = height = interval = mcu_width = 0
    while True:
        if p + 4 > len(jpeg) or jpeg[p] != 255:
            raise ValueError('Spatial JPEG header')
        marker = jpeg[p + 1]
        n = int.from_bytes(jpeg[p + 2:p + 4], 'big')
        if n < 2 or p + 2 + n > len(jpeg):
            raise ValueError('Spatial JPEG marker length')
        body = jpeg[p + 4:p + 2 + n]
        if marker == 0xc0:
            if len(body) < 9 or body[0] != 8:
                raise ValueError('Spatial JPEG SOF')
            height, width = struct.unpack_from('>HH', body, 1)
            if body[5] == 3 and body[7] == 0x21:
                mcu_width = 16
            elif body[5] == 1 and body[7] == 0x11:
                mcu_width = 8
            else:
                raise ValueError('Spatial JPEG sampling')
        elif marker == 0xdd:
            if len(body) != 2:
                raise ValueError('Spatial JPEG DRI')
            interval = int.from_bytes(body, 'big')
        elif marker not in (0xe0, 0xdb, 0xc4, 0xda, 0xfe):
            raise ValueError('Unsupported spatial JPEG marker')
        p += 2 + n
        if marker == 0xda:
            break
    if not all((width, height, interval, mcu_width)) or width % mcu_width or height % 8:
        raise ValueError('Spatial JPEG geometry/DRI')
    # A group must stay within one MCU row, so its index has a fixed rectangle.
    if (width // mcu_width) % interval:
        raise ValueError('Spatial restart interval crosses a row')
    header = jpeg[:p]
    groups = []
    start = p
    while p < len(jpeg):
        # Skip entropy bytes in native code. A Python loop over every byte of a
        # 1080p frame can delay USB reads long enough to overflow the board FIFO.
        p = jpeg.find(b'\xff', p)
        if p < 0:
            raise ValueError('Spatial entropy missing EOI')
        if p + 1 >= len(jpeg):
            raise ValueError('Truncated spatial entropy marker')
        marker = jpeg[p + 1]
        if marker == 0:
            p += 2
            continue
        if 0xd0 <= marker <= 0xd7:
            if marker != 0xd0 + (len(groups) & 7):
                raise ValueError('Spatial restart sequence')
        elif marker != 0xd9 or p + 2 != len(jpeg):
            raise ValueError('Spatial entropy marker/EOI')
        if p == start:
            raise ValueError('Empty spatial entropy group')
        groups.append(jpeg[start:p + 2])
        p += 2
        start = p
    expected = width // mcu_width * (height // 8) // interval
    if start != len(jpeg) or len(groups) != expected or not groups[-1].endswith(b'\xff\xd9'):
        raise ValueError('Spatial group count/EOI')
    return SpatialJPEG(header, tuple(groups), width, height, interval, mcu_width)


class SpatialDecoder:
    def __init__(self):
        self.reset()

    def reset(self):
        self.frame_id = None
        self.reference = None
        self.last_stats = None
        self.threshold = None
        self.adaptive = False

    def decode(self, payload, frame_id):
        # No reference mutation occurs until all records and JPEG structure pass.
        if len(payload) < 12 or payload[:4] not in SPATIAL_MAGICS:
            raise ValueError('Spatial packet magic')
        flags, reference_id = struct.unpack_from('<BI', payload, 4)
        if flags & ~(3 if payload[:4] == THRESHOLD_MAGIC else 1):
            raise ValueError('Spatial packet flags')
        key = bool(flags & 1)
        adaptive = bool(flags & 2)
        if key and reference_id != NONE or not key and (
                self.reference is None or reference_id != self.frame_id or frame_id != reference_id + 1):
            raise ValueError('Spatial reference unavailable/sequence')
        p = 9
        threshold = None
        if payload[:4] == THRESHOLD_MAGIC:
            if len(payload) < 13:
                raise ValueError('Truncated spatial threshold')
            threshold = payload[p]
            p += 1
        if not key and threshold != self.threshold:
            raise ValueError('Spatial threshold changed without refresh')
        if not key and adaptive != self.adaptive:
            raise ValueError('Spatial adaptive mode changed without refresh')
        if payload[p] != 0:
            raise ValueError('Spatial header record')
        n = int.from_bytes(payload[p + 1:p + 3], 'little')
        p += 3
        if not 1 <= n <= 2048 or p + n > len(payload):
            raise ValueError('Spatial header length')
        header = payload[p:p + n]
        p += n
        if not key and header != self.reference.header:
            raise ValueError('Spatial configuration changed without refresh')
        groups = []
        reused = saved = 0
        total = len(header)
        while p < len(payload):
            if p + 3 > len(payload):
                raise ValueError('Truncated spatial record')
            tag, index = struct.unpack_from('<BH', payload, p)
            p += 3
            if index != len(groups) or index >= 65535:
                raise ValueError('Spatial group order')
            if tag == 1:
                if p + 2 > len(payload):
                    raise ValueError('Truncated spatial group length')
                n = int.from_bytes(payload[p:p + 2], 'little')
                p += 2
                if not n or p + n > len(payload):
                    raise ValueError('Spatial group length')
                group = payload[p:p + n]
                p += n
            elif tag == 2 and not key and index < len(self.reference.groups):
                group = self.reference.groups[index]
                reused += 1
                saved += len(group) + 2  # DATA length bytes also omitted.
            else:
                raise ValueError('Spatial record tag/reference')
            total += len(group)
            if total > MAX_FRAME:
                raise ValueError('Spatial reconstructed frame exceeds limit')
            groups.append(group)
        jpeg = header + b''.join(groups)
        parsed = split_jpeg(jpeg)
        if parsed.header != header or parsed.groups != tuple(groups):
            raise ValueError('Spatial record/marker boundaries')
        self.reference = parsed
        self.frame_id = frame_id
        self.threshold = threshold
        self.adaptive = adaptive
        self.last_stats = dict(keyframe=key, groups=len(groups), reused=reused,
                               omitted_group_bytes=saved, jpeg_bytes=len(jpeg), transport_bytes=len(payload),
                               net_saved_bytes=len(jpeg) - len(payload))
        if threshold is not None:
            self.last_stats['threshold'] = threshold
            self.last_stats['adaptive'] = adaptive
        return jpeg


class SpatialEncoder:
    """Host reference/prototype; compares full bytes, never hashes or thresholds."""
    def __init__(self, refresh_period=30):
        self.refresh_period = refresh_period
        self.reference = None
        self.frame_id = None
        self.cached = set()
        self.frames_since_refresh = 0

    def encode(self, jpeg, frame_id, force_refresh=False):
        current = split_jpeg(jpeg)
        key = force_refresh or self.reference is None or frame_id != self.frame_id + 1 or (
            current.header != self.reference.header or self.frames_since_refresh >= self.refresh_period)
        if key:
            self.cached = set(range(len(current.groups)))
            self.frames_since_refresh = 0
        out = bytearray(struct.pack('<4sBI', MAGIC, int(key), NONE if key else self.frame_id))
        out += struct.pack('<BH', 0, len(current.header)) + current.header
        for i, group in enumerate(current.groups):
            if not key and i in self.cached and group == self.reference.groups[i]:
                out += struct.pack('<BH', 2, i)
            else:
                out += struct.pack('<BHH', 1, i, len(group)) + group
        self.reference = current
        self.frame_id = frame_id
        self.frames_since_refresh += 1
        return bytes(out)

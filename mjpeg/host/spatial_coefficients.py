"""Decode Baseline JPEG restart groups for coefficient-domain dead-zone tests.

The comparator uses the maximum absolute difference after multiplying each
quantized coefficient by its JPEG quantization entry. Its threshold is in DCT
coefficient units, not pixel brightness units. A zero threshold means exact
coefficient equality. This module never decodes/re-encodes pixels or changes a
JPEG; a caller choosing COPY must retain the last *emitted* group's reference.

Only the project's grayscale and horizontal 4:2:2 Baseline scans are supported.
Huffman and quantization tables are read from the header, with no dependency on
the testbench's encoder model or Pillow.
"""
from dataclasses import dataclass
import struct

from spatial_jpeg import split_jpeg

# Zigzag position -> natural, row-major DCT coefficient position.
ZIGZAG = (0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
          12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
          35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
          58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63)


@dataclass(frozen=True)
class Component:
    component_id: int
    quantization: tuple
    dc_table: dict
    ac_table: dict


@dataclass(frozen=True)
class JPEGConfig:
    width: int
    height: int
    interval: int
    mcu_width: int
    mcu_components: tuple


@dataclass(frozen=True)
class CoefficientBlock:
    component_id: int
    coefficients: tuple  # quantized, zigzag order
    quantization: tuple  # zigzag order, as stored in DQT

    @property
    def natural_coefficients(self):
        result = [0] * 64
        for position, value in zip(ZIGZAG, self.coefficients):
            result[position] = value
        return tuple(result)

    @property
    def dequantized_coefficients(self):
        return tuple(c * q for c, q in zip(self.coefficients, self.quantization))


@dataclass(frozen=True)
class CoefficientGroup:
    blocks: tuple


def _huffman(counts, values):
    table = {}
    code = position = 0
    for length, count in enumerate(counts, 1):
        if code + count > 1 << length:
            raise ValueError('Oversubscribed JPEG Huffman table')
        for _ in range(count):
            # Baseline tables must not assign an all-one code: pad bits are 1.
            if code == (1 << length) - 1:
                raise ValueError('JPEG Huffman table contains padding code')
            table[length, code] = values[position]
            position += 1
            code += 1
        code <<= 1
    if not table:
        raise ValueError('Empty JPEG Huffman table')
    return table


def parse_header(header):
    """Read DQT/DHT/SOF/SOS/DRI from a complete header ending after SOS."""
    if not header.startswith(b'\xff\xd8'):
        raise ValueError('JPEG header boundary')
    p = 2
    quant = {}
    huffman = {}
    components = None
    width = height = interval = 0
    while p < len(header):
        if p + 4 > len(header) or header[p] != 255:
            raise ValueError('Truncated JPEG header marker')
        marker = header[p + 1]
        size = int.from_bytes(header[p + 2:p + 4], 'big')
        end = p + 2 + size
        if size < 2 or end > len(header):
            raise ValueError('JPEG header marker length')
        body = header[p + 4:end]
        p = end
        if marker == 0xdb:
            at = 0
            while at < len(body):
                info = body[at]
                if info >> 4 or info & 15 > 3 or at + 65 > len(body):
                    raise ValueError('Unsupported/truncated JPEG quantization table')
                values = tuple(body[at + 1:at + 65])
                if not all(values):
                    raise ValueError('Zero JPEG quantization entry')
                quant[info & 15] = values
                at += 65
        elif marker == 0xc4:
            at = 0
            while at < len(body):
                if at + 17 > len(body):
                    raise ValueError('Truncated JPEG Huffman table')
                info = body[at]
                if info >> 4 > 1 or info & 15 > 3:
                    raise ValueError('Unsupported JPEG Huffman table')
                counts = body[at + 1:at + 17]
                size = sum(counts)
                if size > 256 or at + 17 + size > len(body):
                    raise ValueError('JPEG Huffman table length')
                huffman[info >> 4, info & 15] = _huffman(counts, body[at + 17:at + 17 + size])
                at += 17 + size
        elif marker == 0xc0:
            if components is not None or len(body) < 6 or body[0] != 8:
                raise ValueError('Unsupported JPEG SOF')
            height, width = struct.unpack_from('>HH', body, 1)
            count = body[5]
            if count not in (1, 3) or len(body) != 6 + 3 * count:
                raise ValueError('Unsupported JPEG components')
            components = {}
            sampling = []
            for at in range(6, len(body), 3):
                identifier, sample, qid = body[at:at + 3]
                if identifier in components or qid > 3:
                    raise ValueError('JPEG component identifier/table')
                components[identifier] = (sample >> 4, sample & 15, qid)
                sampling.append(sample)
            if sampling != ([0x11] if count == 1 else [0x21, 0x11, 0x11]):
                raise ValueError('Unsupported JPEG sampling')
        elif marker == 0xdd:
            if len(body) != 2:
                raise ValueError('JPEG restart interval length')
            interval = int.from_bytes(body, 'big')
        elif marker == 0xda:
            if components is None or not body or body[0] != len(components):
                raise ValueError('JPEG scan components')
            if len(body) != 1 + 2 * len(components) + 3 or body[-3:] != b'\x00\x3f\x00' or p != len(header):
                raise ValueError('Unsupported JPEG scan/header boundary')
            selected = []
            seen = set()
            for at in range(1, len(body) - 3, 2):
                identifier, tables = body[at:at + 2]
                if identifier not in components or identifier in seen:
                    raise ValueError('JPEG scan component identifier')
                seen.add(identifier)
                horizontal, vertical, qid = components[identifier]
                try:
                    component = Component(identifier, quant[qid],
                                          huffman[0, tables >> 4], huffman[1, tables & 15])
                except KeyError as error:
                    raise ValueError('Missing JPEG quantization/Huffman table') from error
                selected.extend([component] * (horizontal * vertical))
            mcu_width = 8 if len(components) == 1 else 16
            if not width or not height or not interval or width % mcu_width or height % 8 or (width // mcu_width) % interval:
                raise ValueError('JPEG restart geometry')
            return JPEGConfig(width, height, interval, mcu_width, tuple(selected))
        elif marker != 0xfe and not 0xe0 <= marker <= 0xef:
            raise ValueError('Unsupported JPEG header marker')
    raise ValueError('Missing JPEG scan header')


class _Bits:
    def __init__(self, entropy):
        data = bytearray()
        p = 0
        while p < len(entropy):
            value = entropy[p]
            data.append(value)
            p += 1
            if value == 255:
                if p >= len(entropy) or entropy[p] != 0:
                    raise ValueError('Invalid JPEG entropy byte stuffing')
                p += 1
        self.data = data
        self.position = self.accumulator = self.count = 0

    def get(self, size):
        while self.count < size:
            if self.position >= len(self.data):
                raise ValueError('Truncated JPEG entropy')
            self.accumulator = self.accumulator << 8 | self.data[self.position]
            self.position += 1
            self.count += 8
        self.count -= size
        result = self.accumulator >> self.count & ((1 << size) - 1)
        self.accumulator &= (1 << self.count) - 1
        return result

    def finish(self):
        if self.position != len(self.data) or self.count > 7 or self.accumulator != (1 << self.count) - 1:
            raise ValueError('Invalid JPEG entropy padding/trailing bytes')


def _symbol(bits, table):
    code = 0
    for length in range(1, 17):
        code = code << 1 | bits.get(1)
        value = table.get((length, code))
        if value is not None:
            return value
    raise ValueError('Invalid JPEG Huffman code')


def _amplitude(bits, size):
    value = bits.get(size)
    return value if not size or value >= 1 << (size - 1) else value - ((1 << size) - 1)


def decode_restart_group(group, config):
    """Decode exactly ``config.interval`` MCUs; reset each component's DC here."""
    if len(group) < 3 or group[-2] != 255 or group[-1] not in (*range(0xd0, 0xd8), 0xd9):
        raise ValueError('JPEG restart group boundary')
    bits = _Bits(group[:-2])
    previous = {}
    blocks = []
    for _ in range(config.interval):
        for component in config.mcu_components:
            category = _symbol(bits, component.dc_table)
            if category > 11:
                raise ValueError('Invalid JPEG DC category')
            identifier = component.component_id
            dc = previous.get(identifier, 0) + _amplitude(bits, category)
            previous[identifier] = dc
            coefficients = [dc] + [0] * 63
            k = 1
            while k < 64:
                ac = _symbol(bits, component.ac_table)
                if ac == 0:
                    break
                if ac == 0xf0:
                    k += 16
                    if k > 64:
                        raise ValueError('Invalid JPEG zero run')
                    continue
                k += ac >> 4
                size = ac & 15
                if k >= 64 or not 1 <= size <= 10:
                    raise ValueError('Invalid JPEG AC category/run')
                coefficients[k] = _amplitude(bits, size)
                k += 1
            blocks.append(CoefficientBlock(identifier, tuple(coefficients), component.quantization))
    bits.finish()
    return CoefficientGroup(tuple(blocks))


def decode_jpeg_coefficients(jpeg):
    """Return ``(config, tuple_of_decoded_groups)`` after marker-order checks."""
    parsed = split_jpeg(jpeg)
    config = parse_header(parsed.header)
    return config, tuple(decode_restart_group(group, config) for group in parsed.groups)


def _paired_blocks(current, reference):
    if len(current.blocks) != len(reference.blocks):
        raise ValueError('Incompatible coefficient group length')
    for a, b in zip(current.blocks, reference.blocks):
        if a.component_id != b.component_id or a.quantization != b.quantization:
            raise ValueError('Incompatible coefficient component/quantization')
        yield a, b


def max_abs_dequantized_difference(current, reference):
    """Maximum ``abs(current_qcoeff - reference_qcoeff) * DQT`` over a group."""
    maximum = 0
    for a, b in _paired_blocks(current, reference):
        maximum = max(maximum, max(abs(x - y) * q for x, y, q in
                                   zip(a.coefficients, b.coefficients, a.quantization)))
    return maximum


def within_deadzone(current, reference, threshold):
    """True when *every* dequantized coefficient difference is <= threshold.

    Do not replace the reference on a True/COPY result: accumulated small drift
    must eventually exceed the dead zone relative to the receiver's old content.
    """
    if isinstance(threshold, bool) or not isinstance(threshold, int) or threshold < 0:
        raise ValueError('Dead-zone threshold must be a nonnegative integer')
    for a, b in _paired_blocks(current, reference):
        if any(abs(x - y) * q > threshold for x, y, q in
               zip(a.coefficients, b.coefficients, a.quantization)):
            return False
    return True

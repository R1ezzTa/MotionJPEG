"""Numerical checks for the host coefficient-domain dead-zone comparator."""
import dataclasses
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from spatial_coefficients import (CoefficientBlock, CoefficientGroup,
                                  decode_jpeg_coefficients, decode_restart_group,
                                  max_abs_dequantized_difference, parse_header,
                                  within_deadzone)
from spatial_jpeg import split_jpeg
from spatial_reference import BitWriter, HUFF, ZZ, blocks, dct, encode_restart, header, segment, symbols
from jpeg_model import tables


def coefficient_jpeg(group_values, quality=85, gray=False):
    """Independent known-coefficient JPEG; each group has four MCUs."""
    qs = tables(quality)
    original = header(64 if not gray else 32, 8 * len(group_values), gray, qs)
    sos = original.rfind(b'\xff\xda')
    out = bytearray(original[:sos] + segment(0xdd, [0, 4]) + original[sos:])
    for i, values in enumerate(group_values):
        writer = BitWriter()
        previous = [0, 0, 0]
        for _ in range(4):
            for component in ((0,) if gray else (0, 0, 1, 2)):
                coefficients = list(values[component])
                for dc, symbol, amplitude, count in symbols(coefficients, previous[component]):
                    code, length = HUFF[(0 if component == 0 else 2) + (0 if dc else 1)][symbol]
                    writer.put(code, length)
                    writer.put(amplitude, count)
                previous[component] = coefficients[0]
        out.extend(writer.finish())
        out.extend(bytes((255, 0xd9 if i == len(group_values) - 1 else 0xd0 + (i & 7))))
    return bytes(out)


def values(dc=0, chroma=0, ac_position=None, ac_value=0):
    result = [[dc] + [0] * 63, [chroma] + [0] * 63, [-chroma] + [0] * 63]
    if ac_position is not None:
        result[0][ac_position] = ac_value
    return result


class SpatialCoefficientTests(unittest.TestCase):
    def test_real_quantized_coefficients_match_independent_dct(self):
        row, col = np.indices((16, 128))
        y = ((row * 2 + col * 3) & 255).astype(np.uint8)
        cb = ((row[:, :64] * 3 + col[:, :64] * 2 + 60) & 255).astype(np.uint8)
        cr = np.full((16, 64), 160, np.uint8)
        qs = tables(85)
        for gray in (False, True):
            jpeg = encode_restart(y, cb, cr, gray, qs)
            config, groups = decode_jpeg_coefficients(jpeg)
            decoded = [block for group in groups for block in group.blocks]
            expected = []
            for component, block in blocks(y, cb, cr, gray):
                co = dct(block).reshape(64)
                qt = np.array(qs[:64] if component == 0 else qs[64:])
                scan = (np.sign(co) * ((np.abs(co) + qt // 2) // qt))[ZZ]
                expected.append(tuple(int(x) for x in scan))
            self.assertEqual([block.coefficients for block in decoded], expected)
            self.assertEqual(config.mcu_width, 8 if gray else 16)

    def test_dc_resets_for_each_restart_and_component(self):
        jpeg = coefficient_jpeg([values(dc=37, chroma=-9), values(dc=-13, chroma=17)])
        config, groups = decode_jpeg_coefficients(jpeg)
        self.assertEqual(len(groups[0].blocks), 16)
        self.assertEqual([block.coefficients[0] for block in groups[0].blocks[:4]], [37, 37, -9, 9])
        self.assertEqual([block.coefficients[0] for block in groups[1].blocks[:4]], [-13, -13, 17, -17])
        parsed = split_jpeg(jpeg)
        # Decoding the second group alone must not depend on the first group's DC.
        self.assertEqual(decode_restart_group(parsed.groups[1], config), groups[1])

    def test_dequantized_maximum_and_natural_order(self):
        _, (base,) = decode_jpeg_coefficients(coefficient_jpeg([values()]))
        _, (changed,) = decode_jpeg_coefficients(coefficient_jpeg([values(ac_position=2, ac_value=-3)]))
        q = changed.blocks[0].quantization[2]
        self.assertEqual(max_abs_dequantized_difference(changed, base), 3 * q)
        self.assertEqual(changed.blocks[0].natural_coefficients[8], -3)
        self.assertEqual(changed.blocks[0].dequantized_coefficients[2], -3 * q)
        self.assertTrue(within_deadzone(changed, base, 3 * q))
        self.assertFalse(within_deadzone(changed, base, 3 * q - 1))

    def test_zero_threshold_and_chroma_changes(self):
        _, (base,) = decode_jpeg_coefficients(coefficient_jpeg([values()]))
        _, (changed,) = decode_jpeg_coefficients(coefficient_jpeg([values(chroma=1)]))
        self.assertTrue(within_deadzone(base, base, 0))
        self.assertFalse(within_deadzone(changed, base, 0))
        difference = changed.blocks[2].quantization[0]
        self.assertEqual(max_abs_dequantized_difference(changed, base), difference)
        self.assertTrue(within_deadzone(changed, base, difference))

    def test_small_noise_and_accumulated_drift_use_emitted_reference(self):
        decoded = [decode_jpeg_coefficients(coefficient_jpeg([values(dc=dc)]))[1][0]
                   for dc in (0, 1, -1, 2, 3, 4)]
        reference = decoded[0]
        threshold = 2 * reference.blocks[0].quantization[0]
        copied = []
        for current in decoded[1:]:
            keep = within_deadzone(current, reference, threshold)
            copied.append(keep)
            if not keep:
                reference = current
        self.assertEqual(copied, [True, True, True, False, True])
        self.assertEqual(reference.blocks[0].coefficients[0], 3)

    def test_threshold_validation_and_incompatible_configuration(self):
        _, (base,) = decode_jpeg_coefficients(coefficient_jpeg([values()]))
        _, (quality_changed,) = decode_jpeg_coefficients(coefficient_jpeg([values()], quality=60))
        for threshold in (-1, 1.5, None, True):
            with self.assertRaisesRegex(ValueError, 'threshold'):
                within_deadzone(base, base, threshold)
        with self.assertRaisesRegex(ValueError, 'quantization'):
            max_abs_dequantized_difference(base, quality_changed)
        with self.assertRaisesRegex(ValueError, 'length'):
            within_deadzone(base, CoefficientGroup(base.blocks[:-1]), 0)

    def test_malformed_entropy_rejected(self):
        jpeg = coefficient_jpeg([values(dc=37, ac_position=17, ac_value=-3)])
        parsed = split_jpeg(jpeg)
        config = parse_header(parsed.header)
        group = parsed.groups[0]
        for broken in (group[:1] + group[-2:], group[:-2] + b'\x00' + group[-2:],
                       b'\xff\x01' + group, group[:-2] + b'\xff\x00', group[:-1]):
            with self.assertRaises(ValueError):
                decode_restart_group(broken, config)
        # One zero grayscale block uses 6 bits and has two padding bits 1.
        gray_config, _ = decode_jpeg_coefficients(coefficient_jpeg([values()], gray=True))
        one_block = dataclasses.replace(gray_config, interval=1)
        self.assertEqual(len(decode_restart_group(b'\x2b\xff\xd9', one_block).blocks), 1)
        with self.assertRaisesRegex(ValueError, 'padding'):
            decode_restart_group(b'\x2a\xff\xd9', one_block)

    def test_invalid_categories_and_zero_run_are_rejected(self):
        config, _ = decode_jpeg_coefficients(coefficient_jpeg([values()], gray=True))
        component = config.mcu_components[0]
        invalid_dc = dataclasses.replace(component, dc_table={(1, 0): 12})
        with self.assertRaisesRegex(ValueError, 'DC category'):
            decode_restart_group(b'\x7f\xff\xd9', dataclasses.replace(config, mcu_components=(invalid_dc,)))
        invalid_ac = dataclasses.replace(component, dc_table={(1, 0): 0}, ac_table={(1, 0): 0xf0})
        with self.assertRaisesRegex(ValueError, 'zero run'):
            decode_restart_group(b'\x00\xff\xd9', dataclasses.replace(config, mcu_components=(invalid_ac,)))

    def test_malformed_header_tables_rejected(self):
        parsed = split_jpeg(coefficient_jpeg([values()]))
        header_bytes = parsed.header
        quant_at = header_bytes.index(b'\xff\xdb') + 5
        invalid_quant = header_bytes[:quant_at] + b'\x00' + header_bytes[quant_at + 1:]
        with self.assertRaisesRegex(ValueError, 'quantization'):
            parse_header(invalid_quant)
        huff_at = header_bytes.index(b'\xff\xc4') + 5
        invalid_huffman = header_bytes[:huff_at] + b'\xff' + header_bytes[huff_at + 1:]
        with self.assertRaisesRegex(ValueError, 'Huffman'):
            parse_header(invalid_huffman)
        with self.assertRaisesRegex(ValueError, 'boundary'):
            parse_header(header_bytes + b'\x00')
        with self.assertRaises(ValueError):
            parse_header(header_bytes[:-1])


if __name__ == '__main__':
    unittest.main()

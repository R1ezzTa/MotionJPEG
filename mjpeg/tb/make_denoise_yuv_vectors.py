import argparse
import json
import random
from pathlib import Path
from denoise_yuv_reference import denoise_yuv

parser = argparse.ArgumentParser()
parser.add_argument('--width', type=int, default=16)
parser.add_argument('--height', type=int, default=8)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
rng = random.Random(6028)
strengths = (0, 8, 16, 32, 64, 255, 32, 0, 16, 1, 1, 31, 31, 32, 32, 255, 255)
source, expected = [], []
for frame, strength in enumerate(strengths):
    edge = max(1, min(args.width - 2, args.width // 2 + frame % 5 - 2))
    image = []
    for y in range(args.height):
        row = []
        for x in range(args.width):
            base = (48, 80, 160) if x < edge else (208, 176, 96)
            pixel = tuple(max(0, min(255, value + rng.randint(-18, 18))) for value in base)
            if frame == 3 and x == 2 and y == 2:
                pixel = (255, 255, 0)
            if frame == 6 and 1 <= x <= 3 and 1 <= y <= 3:
                pixel = (48, 120, 120)
            if frame >= 9:
                # Exercise both signs and rounding boundaries of the reduced
                # one-multiply blend with original/median separated by 255.
                level = 0 if (frame - 9) % 2 == 0 else 255
                if x == args.width // 2 and y == args.height // 2:
                    level = 255 - level
                pixel = (level, 255 - level, level)
            row.append(pixel)
        image.append(row)
    clean = denoise_yuv(image, strength)
    source.extend(image);expected.extend(clean)
pack = lambda pixel: pixel[0] << 16 | pixel[1] << 8 | pixel[2]
for name, rows in (('rgb', source), ('golden', expected)):
    (args.output / (name + '.mem')).write_text(''.join(f'{pack(pixel):06x}\n' for row in rows for pixel in row))
(args.output / 'strength.mem').write_text(''.join(f'{value:02x}\n' for value in strengths))

flat = [[tuple(128 + rng.randint(-12, 12) for _ in range(3)) for x in range(32)] for y in range(16)]
filtered = denoise_yuv(flat, 32)
mse = lambda image, c: sum((pixel[c] - 128) ** 2 for row in image for pixel in row) / 512
assert denoise_yuv(flat, 0) == flat
assert mse(filtered, 0) < mse(flat, 0) * 0.5
assert mse(filtered, 1) < mse(flat, 1) * 0.15
assert mse(filtered, 2) < mse(flat, 2) * 0.15
step = [[(32, 64, 192) if x < 16 else (224, 192, 64) for x in range(32)] for y in range(16)]
assert denoise_yuv(step, 16) == step
constant = [[(73, 12, 251)] * 16 for _ in range(8)]
assert denoise_yuv(constant, 255) == constant
impulse = [[(120, 128, 128) for _ in range(7)] for _ in range(7)]
impulse[3][3] = (200, 220, 32)
assert denoise_yuv(impulse, 32)[3][3] == (120, 128, 128)
blob = [[(120, 128, 128) for _ in range(7)] for _ in range(7)]
for y in range(2, 5):
    for x in range(2, 5):
        blob[y][x] = (120, 168, 88)
blob_result = denoise_yuv(blob, 32)[3][3]
assert abs(blob_result[1] - 128) < 40 * 0.6 and abs(blob_result[2] - 128) < 40 * 0.6
(args.output / 'reference_summary.json').write_text(json.dumps(dict(
    frames=len(strengths), width=args.width, height=args.height, strengths=strengths,
    zero_exact=True, constant_exact=True, high_contrast_step_exact_at_16=True,
    isolated_outlier_removed_at_32=True, correlated_colour_patch_center=blob_result,
    known_flat_noise_input_mse=[mse(flat, c) for c in range(3)],
    known_flat_noise_output_mse=[mse(filtered, c) for c in range(3)],
    note='Known artificial signals, not camera noise measurements.'), indent=2) + '\n')

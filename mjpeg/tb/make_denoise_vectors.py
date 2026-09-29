import argparse
import json
import random
from pathlib import Path
from denoise_reference import spatial_denoise

parser = argparse.ArgumentParser()
parser.add_argument('--width', type=int, default=16)
parser.add_argument('--height', type=int, default=8)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
rng = random.Random(5684)
strengths = (0, 8, 16, 32, 64, 255, 16, 0, 16)
source, expected = [], []
for frame, strength in enumerate(strengths):
    edge = max(1, min(args.width - 2, args.width // 2 + frame % 5 - 2))
    image = []
    for y in range(args.height):
        row = []
        for x in range(args.width):
            base = (48, 80, 112) if x < edge else (208, 176, 144)
            pixel = tuple(max(0, min(255, value + rng.randint(-12, 12))) for value in base)
            if frame == 4 and x == 2 and y == 2:
                pixel = (255, 255, 255)
            row.append(pixel)
        image.append(row)
    clean = spatial_denoise(image, strength)
    source.extend(image); expected.extend(clean)
pack = lambda pixel: pixel[0] << 16 | pixel[1] << 8 | pixel[2]
for name, rows in (('rgb', source), ('golden', expected)):
    (args.output / (name + '.mem')).write_text(''.join(f'{pack(pixel):06x}\n' for row in rows for pixel in row))
(args.output / 'strength.mem').write_text(''.join(f'{value:02x}\n' for value in strengths))

# Check useful filtering properties against known signals, independently of RTL.
flat = [[(128 + rng.randint(-5, 5),) * 3 for x in range(32)] for y in range(16)]
filtered = spatial_denoise(flat, 16)
mse = lambda image: sum((pixel[0] - 128) ** 2 for row in image for pixel in row) / 512
assert mse(filtered) < mse(flat) * 0.3
assert spatial_denoise(flat, 0) == flat
step = [[(32, 48, 64) if x < 16 else (224, 208, 192) for x in range(32)] for y in range(16)]
assert spatial_denoise(step, 16) == step
assert spatial_denoise([[(12, 73, 251)] * 16 for _ in range(8)], 255) == [[(12, 73, 251)] * 16 for _ in range(8)]
(args.output / 'reference_summary.json').write_text(json.dumps(dict(
    frames=len(strengths), width=args.width, height=args.height, strengths=strengths,
    zero_exact=True, constant_exact=True, high_contrast_edge_exact_at_16=True,
    known_flat_noise_input_mse=mse(flat), known_flat_noise_output_mse=mse(filtered)), indent=2) + '\n')

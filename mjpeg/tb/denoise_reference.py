"""Independent numerical reference, with no stream/pipeline implementation."""


def spatial_denoise(rgb, strength):
    height, width = len(rgb), len(rgb[0])
    if strength == 0:
        return [[tuple(pixel) for pixel in row] for row in rgb]
    weights = ((1, 2, 1), (2, 4, 2), (1, 2, 1))
    def reflect(pos, length):
        return -pos if pos < 0 else (2 * length - 2 - pos if pos >= length else pos)
    result = []
    for y in range(height):
        row = []
        for x in range(width):
            center = rgb[y][x]
            total = [0, 0, 0]
            for dy in range(-1, 2):
                for dx in range(-1, 2):
                    sample = rgb[reflect(y + dy, height)][reflect(x + dx, width)]
                    if max(abs(a - b) for a, b in zip(sample, center)) > strength:
                        sample = center
                    for channel in range(3):
                        total[channel] += weights[dy + 1][dx + 1] * sample[channel]
            row.append(tuple((value + 8) // 16 for value in total))
        result.append(row)
    return result

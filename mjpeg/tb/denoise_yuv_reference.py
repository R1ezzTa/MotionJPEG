"""Full-frame numerical model. Uses sorted nine samples, not RTL networks."""


def reflected(pos, length):
    return -pos if pos < 0 else (2 * length - 2 - pos if pos >= length else pos)


def denoise_yuv(image, strength):
    if strength == 0:
        return [[tuple(pixel) for pixel in row] for row in image]
    height, width = len(image), len(image[0])
    alpha = min(strength, 32)
    median = []
    for y in range(height):
        row = []
        for x in range(width):
            values = [image[reflected(y + dy, height)][reflected(x + dx, width)]
                      for dy in (-1, 0, 1) for dx in (-1, 0, 1)]
            row.append(tuple((image[y][x][channel] * (32 - alpha) +
                              sorted(pixel[channel] for pixel in values)[4] * alpha + 16) // 32
                             for channel in range(3)))
        median.append(row)
    weights = ((1, 2, 1), (2, 4, 2), (1, 2, 1))
    for _ in range(2):
        filtered = []
        for y in range(height):
            row = []
            for x in range(width):
                center = median[y][x]
                total = [0, 0]
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        pixel = median[reflected(y + dy, height)][reflected(x + dx, width)]
                        if abs(pixel[0] - center[0]) > strength:
                            pixel = center
                        for channel in range(2):
                            total[channel] += weights[dy + 1][dx + 1] * pixel[channel + 1]
                row.append((center[0], (total[0] + 8) // 16, (total[1] + 8) // 16))
            filtered.append(row)
        median = filtered
    return median

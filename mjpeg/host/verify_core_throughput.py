"""Validate full-HD raw-core captures and summarize FPGA simulation cycles."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import statistics

from PIL import Image

CLOCK_HZ = 50_000_000
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    if not (args.report / "CORE_THROUGHPUT_SIM_PASS.txt").is_file():
        raise ValueError("Missing independent core simulation pass marker")
    expected = (ROOT / "data/progressive_test/1920x1080.expected.jpg").read_bytes()
    timings = json.loads((args.report / "core_timings.json").read_text())
    if len(timings) != 2:
        raise ValueError("Two full-HD frames required")
    for index, timing in enumerate(timings):
        jpeg = (args.report / f"core_fhd_{index}.jpg").read_bytes()
        if jpeg != expected or timing["frame_id"] != index or timing["jpeg_bytes"] != len(expected):
            raise ValueError("Raw core JPEG or metadata differs from reference")
        if timing["feed_ticks"] - timing["input_wait_ticks"] != 1920 * 1080 - 1:
            raise ValueError("Continuous-input timing coverage mismatch")
        if not 0 < timing["feed_ticks"] <= timing["jpeg_ticks"] <= timing["total_ticks"]:
            raise ValueError("Invalid core completion order")
        with Image.open(io.BytesIO(jpeg)) as image:
            image.load()
            if image.size != (1920, 1080):
                raise ValueError("Core decoder dimensions")
    fps = CLOCK_HZ / statistics.mean(t["total_ticks"] for t in timings)
    result = {"clock_hz": CLOCK_HZ, "width": 1920, "height": 1080, "frames": 2,
              "jpeg_bytes_per_frame": len(expected), "jpeg_sha256": hashlib.sha256(expected).hexdigest(),
              "core_simulated_fps": fps, "core_mpix_s": 1920 * 1080 * fps / 1e6,
              "mean_feed_ms": statistics.mean(t["feed_ticks"] for t in timings) * 1000 / CLOCK_HZ,
              "mean_total_ms": statistics.mean(t["total_ticks"] for t in timings) * 1000 / CLOCK_HZ,
              "input_wait_fraction": sum(t["input_wait_ticks"] for t in timings) / sum(t["feed_ticks"] for t in timings),
              "output_always_ready": True, "continuous_pixel_input": True, "passed": True}
    (args.report / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    (args.report / "VERIFY_PASS.txt").write_text("Two raw 1080p JPEGs equal reference and decode; core simulation timings verified.\n")
    print(json.dumps(result, indent=2))
    print("CORE_THROUGHPUT_REFERENCE_PASS")


if __name__ == "__main__":
    main()

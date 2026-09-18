"""Independent decoding of reassembled JPEG files; no generated-image viewing."""

import sys, json, hashlib, csv, re
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1]
kind = sys.argv[1]
report = root / "reports" / kind
rows = list(csv.DictReader((report / "mjpeg_results.csv").open()))
results = []
for p in sorted(report.glob("*_rtl.jpg")):
    match = re.fullmatch(r"(.+)_ch(\d+)_f(\d+)_rtl.jpg", p.name)
    assert match, p.name
    fixture = match[1]
    expected = bytes(
        int(x, 16) for x in (root / "data" / fixture / "expected.mem").read_text().split()
    )
    data = p.read_bytes()
    assert data == expected, p.name
    with Image.open(p) as im:
        im.load()
        size = im.size
        mode = im.mode
    row = next(
        x
        for x in rows
        if x["case"] == fixture
        and x["channel"] == match[2]
        and x["frame_id"] == match[3]
        and x["status"] == "0"
    )
    assert size == (int(row["width"]), int(row["height"]))
    results.append(
        dict(
            file=p.name,
            size=size,
            mode=mode,
            bytes=len(data),
            sha256=hashlib.sha256(data).hexdigest(),
        )
    )
assert results, "No decoded frames"
if kind == "mjpeg_fhd":
    assert len(rows) == 6 and len(results) == 6
    assert {r["channel"] for r in rows} == {"0", "1"}
    assert all(int(r["cycles"]) <= 3333333 for r in rows)
(report / "decode_results.json").write_text(
    json.dumps(dict(frames=results, descriptors=len(rows)), indent=2)
)
print("MJPEG_DECODE_PASS", kind, "JPEG_FILES", len(results), "DESCRIPTORS", len(rows))

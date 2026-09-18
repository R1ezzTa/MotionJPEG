"""Reference depacketizer for C; consumes accepted (word, bytes, packet_last).

The CSV CLI is for captured FPGA-bus samples. Network/USB packet aggregation
belongs to the transport endpoint and can feed this same receiver.
"""

import csv, json, sys
import struct
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Frame:
    channel: int
    frame_id: int
    timestamp: int
    width: int
    height: int
    gray: bool
    status: int
    length: int
    jpeg: bytes | None


class Receiver:
    def __init__(self, max_frame_bytes=8 * 1024 * 1024):
        self.limit = max_frame_bytes
        self.reset()

    def reset(self):
        self.packet = []
        self.frames = {}

    def packet_words(self, words):
        if self.packet or not 2 <= len(words) <= 7:
            raise ValueError('Invalid complete packet boundary')
        if not words[-1][2] or any(last for _, _, last in words[:-1]):
            raise ValueError('Invalid packet last flags')
        if any(not 0 <= data < 2**32 or not 1 <= nbytes <= 4 for data, nbytes, _ in words):
            raise ValueError('Invalid bus word')
        return self._decode_packet([(data, nbytes) for data, nbytes, _ in words])

    def word(self, data, nbytes, packet_last):
        if not 0 <= data < 2**32 or not 1 <= nbytes <= 4:
            raise ValueError("Invalid bus word")
        self.packet.append((data, nbytes))
        if len(self.packet) > 7:
            raise ValueError("Packet too long")
        if not packet_last:
            return None
        words = self.packet
        self.packet = []
        return self._decode_packet(words)

    def _decode_packet(self, words):
        if len(words) < 2 or words[0][1] != 4 or words[1][1] != 4:
            raise ValueError("Truncated header")
        header = words[0][0]
        if header >> 16 != 0x4D4A or (header >> 12) & 15 != 1:
            raise ValueError("Magic/version")
        kind = (header >> 10) & 3
        channel = (header >> 8) & 3
        key = (channel, words[1][0])
        first = bool(header & 128)
        last = bool(header & 64)
        abort = bool(header & 32)
        count = header & 31
        if kind == 0:
            if (
                count > 16
                or len(words) != 2 + (count + 3) // 4
                or abort != (count == 0)
                or abort
                and not last
            ):
                raise ValueError("Payload size/flags")
            if first:
                if key in self.frames:
                    raise ValueError("Duplicate frame start")
                self.frames[key] = [bytearray(), False, False]
            if key not in self.frames or self.frames[key][1]:
                raise ValueError("Frame order")
            frame = self.frames[key]
            if count == 16:
                if any(n != 4 for _, n in words[2:]):
                    raise ValueError("Partial payload word")
                frame[0].extend(struct.pack('<4I', *(data for data, _ in words[2:])))
            else:
                remaining = count
                for data, nbytes in words[2:]:
                    if nbytes != min(remaining, 4):
                        raise ValueError("Partial payload word")
                    frame[0].extend(data.to_bytes(4, "little")[:nbytes])
                    remaining -= nbytes
            if len(frame[0]) > self.limit:
                raise ValueError("Frame exceeds receive limit")
            if last:
                frame[1] = True
                frame[2] = abort
                if not abort and not (
                    frame[0].startswith(b"\xff\xd8") and frame[0].endswith(b"\xff\xd9")
                ):
                    raise ValueError("JPEG boundary")
            return None
        if (
            kind != 1
            or len(words) != 7
            or count
            or first
            or last
            or abort
            or any(n != 4 for _, n in words)
        ):
            raise ValueError("Descriptor format")
        if key not in self.frames or not self.frames[key][1]:
            raise ValueError("Descriptor before frame end")
        payload, _, aborted = self.frames.pop(key)
        status_word = words[6][0]
        status = status_word & 255
        if status_word >> 9 or status & 240:
            raise ValueError("Reserved status bits")
        length = words[4][0]
        if length != len(payload) or bool(status & 1) != aborted:
            raise ValueError("Descriptor length/abort")
        dimensions = words[5][0]
        return Frame(
            channel,
            key[1],
            words[2][0] | (words[3][0] << 32),
            dimensions & 65535,
            dimensions >> 16,
            bool(status_word & 256),
            status,
            length,
            bytes(payload) if status == 0 else None,
        )


def decode_csv(path):
    receiver = Receiver()
    frames = []
    for row in csv.DictReader(Path(path).open()):
        frame = receiver.word(int(row["data"], 16), int(row["bytes"]), bool(int(row["last"])))
        if frame is not None:
            frames.append(frame)
    if receiver.packet or receiver.frames:
        raise ValueError("Capture ended with incomplete frames")
    return frames


if __name__ == "__main__":
    frames = decode_csv(sys.argv[1])
    dest = Path(sys.argv[2])
    dest.mkdir(parents=True, exist_ok=True)
    metadata = []
    for f in frames:
        if f.jpeg is not None:
            (dest / f"camera{f.channel}_frame{f.frame_id}.jpg").write_bytes(f.jpeg)
        metadata.append({k: v for k, v in vars(f).items() if k != "jpeg"})
    (dest / "frames.json").write_text(json.dumps(metadata, indent=2))
    print("REASSEMBLED_FRAMES", len(frames))

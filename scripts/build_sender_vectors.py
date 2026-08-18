#!/usr/bin/env python3
"""Build a small sender board DDR image from the frames the receiver already uses.

tb/vectors/eth_beats.hex is the known good input to the receiver chain, checked by
every testbench from tb_header_strip up. Packing the same frames into a DDR image
means tb_sender_top can compare what the sender puts on the wire against that file
byte for byte, so one board's output is proven to be the other's input before
either exists in hardware.

Records come from build_replay_image.encode_record, not from a second copy of the
format here, so the testbench fails if that encoder and the RTL ever disagree.

Reads  tb/vectors/eth_bytes.hex  tb/vectors/eth_frames.txt
Writes tb/vectors/sender_image.mem  128 bit words, all extents end to end
       tb/vectors/sender_meta.txt   frames slack base0 beats0 base1 beats1 tx_beats
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_replay_image import BURST_ALIGN, MEM_WORD_BYTES, encode_record

ZERO_RECORD = encode_record(b"", 0)

# each extent is its own DDR allocation on the board, so its base is page aligned.
# This image lays them end to end, and a 256 byte burst issued from a base that is
# only 256 aligned can straddle a 4 KB boundary, which AXI forbids. Padding the
# placement to a page reproduces what the allocator would hand out.
PAGE = 4096

# eth_bytes.hex keeps the frame check sequence, eth_beats.hex does not: the receive
# MAC checks it and hands the fabric the frame without it. The transmit MAC appends
# its own, so what the sender puts in DDR is the frame minus those four bytes,
# which is what build_replay_image builds too, with fcs=False.
FCS_LEN = 4


def load_frames(vectors: Path):
    raw = bytes(int(line, 16) for line in
                (vectors / "eth_bytes.hex").read_text().split())
    frames = []
    for line in (vectors / "eth_frames.txt").read_text().splitlines():
        f = line.split()
        if len(f) < 2 or line.startswith("#"):
            continue
        off, ln = int(f[0]), int(f[1])
        frames.append(raw[off:off + ln - FCS_LEN])
    return frames


def pad_extent(buf: bytearray, align: int) -> None:
    while len(buf) % align:
        buf += ZERO_RECORD


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", type=Path, default=Path("tb/vectors"))
    ap.add_argument("--frames", type=int, default=400,
                    help="frames to pack, 0 for every frame in eth_frames.txt")
    ap.add_argument("--slack", type=int, default=8,
                    help="pacing period is the frame's own beats plus this, so the "
                         "gap between frame starts is exactly the period")
    args = ap.parse_args()

    frames = load_frames(args.vectors)
    if not frames:
        print("no frames, run scripts/eth_encapsulate.py first")
        return 1
    if args.frames:
        frames = frames[:args.frames]

    beats = sum(-(-len(f) // 8) for f in frames)

    # two extents so the read master's extent walk is exercised, split on a frame
    # boundary near the middle
    half = len(frames) // 2
    ext = [bytearray(), bytearray()]
    for i, frame in enumerate(frames):
        period = -(-len(frame) // 8) + args.slack
        ext[0 if i < half else 1] += encode_record(frame, period)
    pad_extent(ext[0], PAGE)
    pad_extent(ext[1], BURST_ALIGN)

    image = bytes(ext[0] + ext[1])
    words = [image[i:i + MEM_WORD_BYTES] for i in range(0, len(image), MEM_WORD_BYTES)]
    (args.vectors / "sender_image.mem").write_text(
        "".join(f"{int.from_bytes(w, 'little'):032X}\n" for w in words), newline="\n")

    base = [0, len(ext[0])]
    meta = [len(frames), args.slack,
            base[0], len(ext[0]) // MEM_WORD_BYTES,
            base[1], len(ext[1]) // MEM_WORD_BYTES,
            beats]
    (args.vectors / "sender_meta.txt").write_text(
        " ".join(str(v) for v in meta) + "\n", newline="\n")

    print(f"frames        {len(frames)}")
    print(f"tx beats      {beats}   expected from eth_beats.hex")
    print(f"extent 0      {len(ext[0])} bytes, {len(ext[0]) // MEM_WORD_BYTES} beats")
    print(f"extent 1      {len(ext[1])} bytes, {len(ext[1]) // MEM_WORD_BYTES} beats")
    print(f"image         {len(words)} words -> sender_image.mem")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

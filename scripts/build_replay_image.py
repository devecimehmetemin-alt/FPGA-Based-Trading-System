#!/usr/bin/env python3
"""Build the sender board DDR replay image: real ITCH traffic split into constant-rate segments."""

from __future__ import annotations

import argparse
import ipaddress
import random
import struct
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from eth_encapsulate import (
    DEFAULT_DST_IP,
    DEFAULT_DST_PORT,
    DEFAULT_SRC_IP,
    DEFAULT_SRC_MAC,
    DEFAULT_SRC_PORT,
    build_frame,
    build_ipv4,
    build_udp,
    multicast_mac_for,
    parse_mac,
)
from mold_packetize import (
    DEFAULT_MTU_PAYLOAD,
    group_into_packets,
    read_itch_messages,
    serialise_packet,
)

CLOCK_HZ = 156_250_000
BYTES_PER_CYCLE = 8
WIRE_OVERHEAD = 24
RECORD_HEADER = 8
BURST_ALIGN = 256
MEM_WORD_BYTES = 16
MAX_PER_PACKET = 42

DEFAULT_PLAN = ("10:1000:42,5:500:42,2.5:300:42,1:250:42,0.5:250:42,"
                "0.25:200:42,0.1:200:42,0.05:150:42,0.01:100:42,0.0043:60:42")
DEFAULT_EXTENT_MIB = 1536
DEFAULT_SKIP = 220_000


def parse_plan(text: str):
    plan = []
    for entry in text.split(","):
        fields = entry.strip().split(":")
        if len(fields) != 3:
            raise ValueError(f"{entry!r} is not RATE_GBPS:MEGABYTES:MAX_MSGS_PER_PACKET")
        rate, megabytes, per_packet = float(fields[0]), int(fields[1]), int(fields[2])
        if rate <= 0 or rate > 10:
            raise ValueError(f"{rate} Gb/s is outside the 10GbE link rate")
        if megabytes <= 0:
            raise ValueError(f"{megabytes} MB is not a segment size")
        if not 0 <= per_packet <= MAX_PER_PACKET:
            raise ValueError(f"{per_packet} is outside 1..{MAX_PER_PACKET} messages per packet")
        plan.append((rate, megabytes * 1_000_000, per_packet or MAX_PER_PACKET))
    return plan


def period_cycles(frame_len: int, rate_gbps: float) -> int:
    wire = frame_len + WIRE_OVERHEAD
    floor = -(-wire // BYTES_PER_CYCLE)
    period = round(wire * 8 * CLOCK_HZ / (rate_gbps * 1e9))
    return max(period, floor)


def encode_record(frame: bytes, period: int) -> bytes:
    padded = frame + bytes(-len(frame) % BYTES_PER_CYCLE)
    return struct.pack("<HHI", len(frame), 0, period) + padded


def write_mem(path: Path, source: Path) -> None:
    width = MEM_WORD_BYTES * 2
    with source.open("rb") as handle, path.open("w", newline="\n") as out:
        for block in iter(lambda: handle.read(MEM_WORD_BYTES), b""):
            out.write(f"{int.from_bytes(block.ljust(MEM_WORD_BYTES, bytes(1)), 'little'):0{width}X}\n")


class ExtentWriter:
    def __init__(self, outdir: Path, stem: str, capacity: int, want_mem: bool):
        self.outdir = outdir
        self.stem = stem
        self.capacity = capacity
        self.want_mem = want_mem
        self.index = -1
        self.handle = None
        self.written = 0
        self.extents = []
        self._open_next()

    def _path(self) -> Path:
        return self.outdir / f"{self.stem}.ext{self.index}.bin"

    def _finish(self) -> None:
        if self.handle is None:
            return
        pad = -self.written % BURST_ALIGN
        if pad:
            self.handle.write(struct.pack("<HHI", 0, 0, 0) * (pad // RECORD_HEADER))
            self.written += pad
        self.handle.close()
        self.handle = None
        self.extents.append((self.index, self.written))
        if self.want_mem:
            write_mem(self._path().with_suffix(".mem"), self._path())

    def _open_next(self) -> None:
        self._finish()
        self.index += 1
        self.written = 0
        self.handle = self._path().open("wb")

    def append(self, record: bytes) -> None:
        if self.written + len(record) + BURST_ALIGN > self.capacity:
            self._open_next()
        self.handle.write(record)
        self.written += len(record)

    def close(self):
        self._finish()
        return self.extents


class PacketSource:
    def __init__(self, path: Path, skip: int, session: str, mtu_payload: int,
                 start_seq: int, seed: int):
        self.messages = read_itch_messages(path, None, skip)
        self.session = session
        self.mtu_payload = mtu_payload
        self.sequence = start_seq
        self.rng = random.Random(seed)
        self.max_per_packet = MAX_PER_PACKET
        self.residual = deque()
        self.exhausted = False

    def _fill(self, want: int) -> None:
        while len(self.residual) < want and not self.exhausted:
            message = next(self.messages, None)
            if message is None:
                self.exhausted = True
            else:
                self.residual.append(message)

    def next_packet(self):
        want = self.rng.randint(1, self.max_per_packet)
        self._fill(want)
        if not self.residual:
            return None, 0
        take = [self.residual[i] for i in range(min(want, len(self.residual)))]
        sequence, group = group_into_packets(take, self.mtu_payload, want, self.sequence)[0]
        for _ in range(len(group)):
            self.residual.popleft()
        self.sequence = sequence + len(group)
        return serialise_packet(self.session, sequence, group), len(group)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", type=Path)
    parser.add_argument("--outdir", type=Path, default=Path("host"))
    parser.add_argument("--stem", default="replay")
    parser.add_argument("--plan", default=DEFAULT_PLAN,
                        help="comma separated RATE_GBPS:MEGABYTES:MAX_MSGS_PER_PACKET; "
                             "each packet draws uniformly from 1 to that maximum, "
                             "0 means the 42 message ceiling")
    parser.add_argument("--extent-mib", type=int, default=DEFAULT_EXTENT_MIB,
                        help="bytes per contiguous DDR extent; the Zynq map splits "
                             "4 GB into a 2 GB low and a 2 GB high region")
    parser.add_argument("--skip", type=int, default=DEFAULT_SKIP,
                        help="discard the first N messages of administrative records")
    parser.add_argument("--session", default="TESTSESS")
    parser.add_argument("--start-seq", type=int, default=1)
    parser.add_argument("--seed", type=int, default=0,
                        help="seed for the per packet message count draw")
    parser.add_argument("--mtu-payload", type=int, default=DEFAULT_MTU_PAYLOAD)
    parser.add_argument("--src-mac", default=DEFAULT_SRC_MAC)
    parser.add_argument("--dst-ip", default=DEFAULT_DST_IP)
    parser.add_argument("--src-ip", default=DEFAULT_SRC_IP)
    parser.add_argument("--dst-port", type=int, default=DEFAULT_DST_PORT)
    parser.add_argument("--src-port", type=int, default=DEFAULT_SRC_PORT)
    parser.add_argument("--ttl", type=int, default=16)
    parser.add_argument("--udp-checksum", action="store_true",
                        help="compute UDP checksums; header_strip ignores them and "
                             "they cost most of the build time")
    parser.add_argument("--mem", action="store_true",
                        help="also emit a 128-bit .mem per extent for $readmemh")
    parser.add_argument("--plan-only", action="store_true",
                        help="print the segment table without reading the capture")
    args = parser.parse_args()

    try:
        plan = parse_plan(args.plan)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    capacity = args.extent_mib * 1024 * 1024
    total_bytes = sum(size for _, size, _ in plan)

    if args.plan_only:
        print(f"{'rate':>10} {'MB':>7} {'msgs/pkt':>9} {'est s':>8}")
        for rate, size, per_packet in plan:
            print(f"{rate:>9}G {size // 1_000_000:>7} {'1-' + str(per_packet):>9} "
                  f"{size * 8 / (rate * 1e9):>8.2f}")
        print(f"total {total_bytes / 1e6:.0f} MB, "
              f"{sum(s * 8 / (r * 1e9) for r, s, _ in plan):.1f} s, "
              f"{-(-total_bytes // capacity)} extents of {args.extent_mib} MiB")
        return 0

    if not args.input.is_file():
        print(f"error: {args.input} not found", file=sys.stderr)
        return 1

    args.outdir.mkdir(parents=True, exist_ok=True)
    src_ip = ipaddress.IPv4Address(args.src_ip)
    dst_ip = ipaddress.IPv4Address(args.dst_ip)
    dst_mac = multicast_mac_for(dst_ip)
    src_mac = parse_mac(args.src_mac)

    source = PacketSource(args.input, args.skip, args.session,
                          args.mtu_payload, args.start_seq, args.seed)
    writer = ExtentWriter(args.outdir, args.stem, capacity, args.mem)
    manifest = []
    identifier = 0
    grand_frames = grand_messages = grand_wire = grand_cycles = 0

    for index, (rate, target, per_packet) in enumerate(plan):
        source.max_per_packet = per_packet
        emitted = frames = messages = wire = cycles = 0
        first_extent = writer.index
        start_offset = writer.written
        while emitted < target:
            payload, count = source.next_packet()
            if payload is None:
                print(f"warning: capture exhausted during segment {index}", file=sys.stderr)
                break
            udp = build_udp(src_ip, dst_ip, args.src_port, args.dst_port,
                            payload, args.udp_checksum)
            ipv4 = build_ipv4(src_ip, dst_ip, identifier, args.ttl, udp)
            frame, _, _ = build_frame(dst_mac, src_mac, ipv4, False, False, False)
            identifier = (identifier + 1) & 0xFFFF
            period = period_cycles(len(frame), rate)
            writer.append(encode_record(frame, period))
            emitted += RECORD_HEADER + len(frame) + (-len(frame) % BYTES_PER_CYCLE)
            frames += 1
            messages += count
            wire += len(frame) + WIRE_OVERHEAD
            cycles += period
        seconds = cycles / CLOCK_HZ
        achieved = wire * 8 / seconds / 1e9 if seconds else 0.0
        manifest.append((index, rate, achieved, seconds, emitted, frames, messages,
                         first_extent, start_offset))
        grand_frames += frames
        grand_messages += messages
        grand_wire += wire
        grand_cycles += cycles
        print(f"segment {index}: {rate:g} Gb/s target, {achieved:.4f} Gb/s actual, "
              f"{seconds:.2f} s, {emitted / 1e6:.1f} MB, {frames} frames, {messages} messages")

    extents = writer.close()

    lines = ["# segment rate_gbps achieved_gbps seconds ddr_bytes frames messages extent offset"]
    for row in manifest:
        lines.append("{} {:g} {:.6f} {:.3f} {} {} {} {} {}".format(*row))
    lines.append("# extent bytes")
    for extent, size in extents:
        lines.append(f"# {extent} {size}")
    (args.outdir / f"{args.stem}.manifest.txt").write_text(
        "\n".join(lines) + "\n", newline="\n")

    print(f"total     {grand_frames} frames, {grand_messages} messages, "
          f"{grand_wire / 1e6:.0f} MB on the wire, {grand_cycles / CLOCK_HZ:.1f} s")
    for extent, size in extents:
        print(f"extent {extent}: {size} bytes ({size / 1024 / 1024:.1f} MiB) "
              f"-> {args.outdir}/{args.stem}.ext{extent}.bin")
    return 0


if __name__ == "__main__":
    sys.exit(main())

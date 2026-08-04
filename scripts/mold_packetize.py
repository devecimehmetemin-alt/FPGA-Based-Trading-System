#!/usr/bin/env python3
"""Wrap ITCH messages in MoldUDP64 packets: emit simulation vectors, send over UDP, or both.

Input: Nasdaq ITCH BinaryFILE, a bare sequence of [2-byte BE length][message].
A .gz input is streamed decompressed, so the multi-GB archive needs no unpacking.

Outputs into --outdir (suppress with --no-vectors):
  mold_bytes.hex    one byte per line, all emitted packets concatenated
  mold_packets.txt  per packet: <byte_offset> <byte_length> <sequence> <msg_count>
  mold_beats.hex    one 32-bit AXI-Stream beat per line, for $readmemh
  itch_expect.hex   one byte per line, messages the deframer should emit
  itch_expect.txt   per message: <byte_offset> <byte_length> <sequence> <type_char>

A mold_beats.hex line is 10 hex digits holding {2'b00, 1'b0, last, keep[3:0],
data[31:0]} -- read it into a logic [39:0] array. Bytes pack little-endian
within a beat, so packet byte 0 lands in data[7:0], and last is set on the
final beat of every packet. Bit 37 is where eth_beats.hex carries fcs_ok; it is
always zero here, so compare bits [36:0]. This is byte for byte what
header_strip emits from the frames eth_encapsulate.py builds around these
packets, which makes it that module's expected output as well.

--send HOST:PORT transmits the same packets as UDP payloads. The OS adds
UDP/IP/Ethernet; nothing below UDP is under our control.

Sequence numbers count messages, not packets: a header carries the sequence of
its first message. --drop exploits this -- dropped packets still consume their
sequence range, so the receiver sees a genuine gap.
"""

from __future__ import annotations

import argparse
import gzip
import socket
import struct
import sys
import time
from pathlib import Path

SESSION_LEN = 10
MOLD_HEADER_LEN = SESSION_LEN + 8 + 2
DEFAULT_MTU_PAYLOAD = 1472  # 1500 MTU - 20 IPv4 - 8 UDP
DEFAULT_MESSAGE_LIMIT = 100_000


def open_itch(path: Path):
    if path.suffix == ".gz":
        return gzip.open(path, "rb")
    return path.open("rb")


def read_itch_messages(path: Path, limit: int | None, skip: int = 0):
    count = 0
    seen = 0
    with open_itch(path) as handle:
        while True:
            prefix = handle.read(2)
            if not prefix:
                return
            if len(prefix) < 2:
                raise ValueError("truncated length prefix at end of file")
            (length,) = struct.unpack(">H", prefix)
            if length == 0:
                raise ValueError(f"zero-length message after {seen} messages")
            message = handle.read(length)
            if len(message) < length:
                raise ValueError(
                    f"truncated message after {seen}: wanted {length}, got {len(message)}"
                )
            seen += 1
            if seen <= skip:
                continue
            yield message
            count += 1
            if limit is not None and count >= limit:
                return


def group_into_packets(messages, mtu_payload: int, max_count: int, start_seq: int):
    packets = []
    current: list[bytes] = []
    current_len = MOLD_HEADER_LEN
    sequence = start_seq

    for message in messages:
        block_len = 2 + len(message)
        if MOLD_HEADER_LEN + block_len > mtu_payload:
            raise ValueError(
                f"{len(message)}-byte message exceeds the {mtu_payload}-byte budget"
            )
        if current and (current_len + block_len > mtu_payload or len(current) >= max_count):
            packets.append((sequence, current))
            sequence += len(current)
            current, current_len = [], MOLD_HEADER_LEN
        current.append(message)
        current_len += block_len

    if current:
        packets.append((sequence, current))
    return packets


def serialise_packet(session: str, sequence: int, messages: list[bytes]) -> bytes:
    out = bytearray()
    out += session.encode("ascii").ljust(SESSION_LEN)[:SESSION_LEN]
    out += struct.pack(">Q", sequence)
    out += struct.pack(">H", len(messages))
    for message in messages:
        out += struct.pack(">H", len(message))
        out += message
    return bytes(out)


def write_hex(path: Path, data: bytes) -> None:
    with path.open("w", newline="\n") as handle:
        for byte in data:
            handle.write(f"{byte:02X}\n")


def pack_beats(data: bytes) -> list[int]:
    beats = []
    for start in range(0, len(data), 4):
        chunk = data[start:start + 4]
        word = int.from_bytes(chunk.ljust(4, b"\x00"), "little")
        last = start + len(chunk) >= len(data)
        keep = (1 << len(chunk)) - 1
        beats.append((last << 36) | (keep << 32) | word)
    return beats


def write_beats(path: Path, beats: list[int]) -> None:
    with path.open("w", newline="\n") as handle:
        for beat in beats:
            handle.write(f"{beat:010X}\n")


def is_multicast(host: str) -> bool:
    try:
        return 224 <= int(socket.inet_aton(host)[0]) <= 239
    except OSError:
        return False


def make_socket(host: str, ttl: int, iface: str | None) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if is_multicast(host):
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, ttl)
        if iface:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                            socket.inet_aton(iface))
    elif iface:
        sock.bind((iface, 0))
    return sock


def send_packets(blobs: list[bytes], host: str, port: int, pps: float,
                 ttl: int, iface: str | None) -> None:
    sock = make_socket(host, ttl, iface)
    interval = 1.0 / pps if pps > 0 else 0.0
    deadline = time.perf_counter()
    sent_bytes = 0
    started = time.perf_counter()

    try:
        for index, blob in enumerate(blobs):
            sock.sendto(blob, (host, port))
            sent_bytes += len(blob)
            if interval:
                deadline += interval
                remaining = deadline - time.perf_counter()
                if remaining > 0:
                    time.sleep(remaining)
            if (index + 1) % 10000 == 0:
                print(f"  sent {index + 1}/{len(blobs)} packets")
    finally:
        sock.close()

    elapsed = max(time.perf_counter() - started, 1e-9)
    print(f"sent      {len(blobs)} packets, {sent_bytes} payload bytes "
          f"in {elapsed:.2f}s ({sent_bytes * 8 / elapsed / 1e6:.1f} Mbps payload)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", type=Path)
    parser.add_argument("--outdir", type=Path, default=Path("tb/vectors"))
    parser.add_argument("--no-vectors", action="store_true",
                        help="skip writing hex vectors (they are large)")
    parser.add_argument("--session", default="TESTSESS")
    parser.add_argument("--start-seq", type=int, default=1)
    parser.add_argument("--mtu-payload", type=int, default=DEFAULT_MTU_PAYLOAD)
    parser.add_argument("--max-count", type=int, default=0xFFFE,
                        help="messages per packet; 0xFFFF is reserved for end-of-session")
    parser.add_argument("--limit", type=int, default=DEFAULT_MESSAGE_LIMIT,
                        help="stop after N messages; 0 means no limit")
    parser.add_argument("--skip", type=int, default=0,
                        help="discard the first N messages; the file opens with "
                             "~220k administrative records before any order flow")
    parser.add_argument("--drop", default=None,
                        help="comma-separated packet indices to drop, creating gaps")
    parser.add_argument("--send", default=None, metavar="HOST:PORT",
                        help="transmit packets as UDP to this destination")
    parser.add_argument("--pps", type=float, default=0.0,
                        help="pace at N packets/sec; 0 sends as fast as possible")
    parser.add_argument("--ttl", type=int, default=1,
                        help="multicast TTL; 1 keeps traffic on the local link")
    parser.add_argument("--iface", default=None, metavar="IP",
                        help="source interface IP, for hosts with several NICs")
    args = parser.parse_args()

    if not args.input.is_file():
        print(f"error: {args.input} not found", file=sys.stderr)
        return 1

    host = port = None
    if args.send:
        host, _, port_text = args.send.rpartition(":")
        if not host or not port_text.isdigit():
            print(f"error: --send wants HOST:PORT, got {args.send}", file=sys.stderr)
            return 1
        port = int(port_text)

    limit = None if args.limit == 0 else args.limit
    drops = {int(i) for i in args.drop.split(",") if i.strip()} if args.drop else set()

    messages = read_itch_messages(args.input, limit, args.skip)
    packets = group_into_packets(messages, args.mtu_payload, args.max_count, args.start_seq)

    unknown = {i for i in drops if i >= len(packets)}
    if unknown:
        print(f"error: --drop names nonexistent packets: {sorted(unknown)}", file=sys.stderr)
        return 1

    blobs, stimulus, expected = [], bytearray(), bytearray()
    packet_lines, message_lines = [], []
    beats = []

    for index, (sequence, group) in enumerate(packets):
        if index in drops:
            continue
        blob = serialise_packet(args.session, sequence, group)
        blobs.append(blob)
        packet_lines.append(f"{len(stimulus)} {len(blob)} {sequence} {len(group)}")
        stimulus += blob
        beats += pack_beats(blob)
        for offset, message in enumerate(group):
            kind = chr(message[0]) if 32 <= message[0] < 127 else "?"
            message_lines.append(
                f"{len(expected)} {len(message)} {sequence + offset} {kind}"
            )
            expected += message

    total = sum(len(group) for _, group in packets)
    print(f"read      {total} messages")
    print(f"packed    {len(packets)} packets "
          f"(avg {total / max(len(packets), 1):.1f} messages/packet)")
    print(f"emitted   {len(blobs)} packets, {len(stimulus)} payload bytes")
    if drops:
        print(f"dropped   packets {sorted(drops)}")

    if not args.no_vectors:
        args.outdir.mkdir(parents=True, exist_ok=True)
        write_hex(args.outdir / "mold_bytes.hex", bytes(stimulus))
        write_beats(args.outdir / "mold_beats.hex", beats)
        write_hex(args.outdir / "itch_expect.hex", bytes(expected))
        (args.outdir / "mold_packets.txt").write_text(
            "\n".join(packet_lines) + "\n", newline="\n")
        (args.outdir / "itch_expect.txt").write_text(
            "\n".join(message_lines) + "\n", newline="\n")
        print(f"wrote     {args.outdir}/ ({len(message_lines)} expected messages, "
              f"{len(beats)} beats)")

    if args.send:
        print(f"sending   to {host}:{port}"
              f"{' (multicast)' if is_multicast(host) else ''}"
              f"{f' at {args.pps:g} pps' if args.pps > 0 else ' unpaced'}")
        send_packets(blobs, host, port, args.pps, args.ttl, args.iface)

    return 0


if __name__ == "__main__":
    sys.exit(main())
